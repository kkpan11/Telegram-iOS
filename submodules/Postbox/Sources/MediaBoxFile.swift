import Foundation
import SwiftSignalKit
import ManagedFile
import RangeSet

private class MediaBoxPartialFileDataRequest {
    let range: Range<Int64>
    var waitingUntilAfterInitialFetch: Bool
    let completion: (MediaResourceData) -> Void
    
    init(range: Range<Int64>, waitingUntilAfterInitialFetch: Bool, completion: @escaping (MediaResourceData) -> Void) {
        self.range = range
        self.waitingUntilAfterInitialFetch = waitingUntilAfterInitialFetch
        self.completion = completion
    }
}

final class MediaBoxPartialFile {
    private let queue: Queue
    private let manager: MediaBoxFileManager
    private let storageBox: StorageBox
    private let resourceId: Data
    private let path: String
    private let metaPath: String
    private let completePath: String
    private let completed: (Int64) -> Void
    private let fd: MediaBoxFileManager.Item
    fileprivate let fileMap: MediaBoxFileMap
    private var dataRequests = Bag<MediaBoxPartialFileDataRequest>()
    private let missingRanges: MediaBoxFileMissingRanges
    private let rangeStatusRequests = Bag<((RangeSet<Int64>) -> Void, () -> Void)>()
    private let statusRequests = Bag<((MediaResourceStatus) -> Void, Int64?)>()
    
    private let fullRangeRequests = Bag<Disposable>()
    
    private var currentFetch: (Promise<[(Range<Int64>, MediaBoxFetchPriority)]>, Disposable)?
    private var processedAtLeastOneFetch: Bool = false
    
    init?(queue: Queue, manager: MediaBoxFileManager, storageBox: StorageBox, resourceId: Data, path: String, metaPath: String, completePath: String, completed: @escaping (Int64) -> Void) {
        assert(queue.isCurrent())
        self.manager = manager
        self.storageBox = storageBox
        self.resourceId = resourceId
        
        if let fd = manager.open(path: path, mode: .readwrite) {
            self.queue = queue
            self.path = path
            self.metaPath = metaPath
            self.completePath = completePath
            self.completed = completed
            self.fd = fd
            if let fileMap = try? MediaBoxFileMap.read(manager: manager, path: self.metaPath) {
                if !fileMap.ranges.isEmpty {
                    let upperBound = fileMap.ranges.ranges.last!.upperBound
                    if let actualSize = fileSize(path, useTotalFileAllocatedSize: false) {
                        if upperBound > actualSize {
                            self.fileMap = MediaBoxFileMap()
                        } else {
                            self.fileMap = fileMap
                        }
                    } else {
                        self.fileMap = MediaBoxFileMap()
                    }
                } else {
                    self.fileMap = fileMap
                }
            } else {
                self.fileMap = MediaBoxFileMap()
            }
            self.storageBox.update(id: self.resourceId, size: self.fileMap.sum)
            self.missingRanges = MediaBoxFileMissingRanges()
        } else {
            return nil
        }
    }
    
    deinit {
        self.currentFetch?.1.dispose()
    }
    
    static func extractPartialData(manager: MediaBoxFileManager, path: String, metaPath: String, range: Range<Int64>) -> Data? {
        guard let fd = ManagedFile(queue: nil, path: path, mode: .read) else {
            return nil
        }
        guard let fileMap = try? MediaBoxFileMap.read(manager: manager, path: metaPath) else {
            return nil
        }
        guard let clippedRange = fileMap.contains(range) else {
            return nil
        }
        let _ = fd.seek(position: Int64(clippedRange.lowerBound))
        return fd.readData(count: Int(clippedRange.upperBound - clippedRange.lowerBound))
    }
    
    static func internal_extractPartialData(manager: MediaBoxFileManager, path: String, metaPath: String, range: Range<Int64>) -> (file: ManagedFile, length: Int)? {
        guard let fd = ManagedFile(queue: nil, path: path, mode: .read) else {
            return nil
        }
        guard let fileMap = try? MediaBoxFileMap.read(manager: manager, path: metaPath) else {
            return nil
        }
        guard let clippedRange = fileMap.contains(range) else {
            return nil
        }
        let _ = fd.seek(position: Int64(clippedRange.lowerBound))
        return (fd, Int(clippedRange.upperBound - clippedRange.lowerBound))
    }
    
    static func internal_isPartialDataCached(manager: MediaBoxFileManager, path: String, metaPath: String, range: Range<Int64>) -> Bool {
        guard let fileMap = try? MediaBoxFileMap.read(manager: manager, path: metaPath) else {
            return false
        }
        guard let _ = fileMap.contains(range) else {
            return false
        }
        return true
    }
    
    var storedSize: Int64 {
        assert(self.queue.isCurrent())
        return self.fileMap.sum
    }
    
    func reset() {
        assert(self.queue.isCurrent())
        
        self.fileMap.reset()
        self.fileMap.serialize(manager: self.manager, to: self.metaPath)
        
        for request in self.dataRequests.copyItems() {
            request.completion(MediaResourceData(path: self.path, offset: request.range.lowerBound, size: 0, complete: false))
        }
        
        if let updatedRanges = self.missingRanges.reset(fileMap: self.fileMap) {
            self.updateRequestRanges(updatedRanges, fetch: nil)
        }
        
        if !self.rangeStatusRequests.isEmpty {
            let ranges = self.fileMap.ranges
            for (f, _) in self.rangeStatusRequests.copyItems() {
                f(ranges)
            }
        }
        
        self.updateStatuses()
    }
    
    func moveLocalFile(tempPath: String) {
        assert(self.queue.isCurrent())
        
        do {
            try FileManager.default.moveItem(atPath: tempPath, toPath: self.completePath)
            
            if let size = fileSize(self.completePath) {
                unlink(self.path)
                unlink(self.metaPath)
                
                for (_, completion) in self.missingRanges.clear() {
                    completion()
                }
                
                if let (_, disposable) = self.currentFetch {
                    self.currentFetch = nil
                    disposable.dispose()
                }
                
                for request in self.dataRequests.copyItems() {
                    request.completion(MediaResourceData(path: self.completePath, offset: request.range.lowerBound, size: max(0, size - request.range.lowerBound), complete: true))
                }
                self.dataRequests.removeAll()
                
                for statusRequest in self.statusRequests.copyItems() {
                    statusRequest.0(.Local)
                }
                self.statusRequests.removeAll()
                
                self.storageBox.update(id: self.resourceId, size: self.fileMap.sum)
                
                self.completed(self.fileMap.sum)
            } else {
                assertionFailure()
            }
        } catch let e {
            postboxLog("moveLocalFile error: \(e)")
            assertionFailure()
        }
    }
    
    func copyLocalItem(_ item: MediaResourceDataFetchCopyLocalItem) {
        assert(self.queue.isCurrent())
        
        do {
            if item.copyTo(url: URL(fileURLWithPath: self.completePath)) {
                
            } else {
                return
            }
            
            if let size = fileSize(self.completePath) {
                unlink(self.path)
                unlink(self.metaPath)
                
                for (_, completion) in self.missingRanges.clear() {
                    completion()
                }
                
                if let (_, disposable) = self.currentFetch {
                    self.currentFetch = nil
                    disposable.dispose()
                }
                
                for request in self.dataRequests.copyItems() {
                    request.completion(MediaResourceData(path: self.completePath, offset: request.range.lowerBound, size: max(0, size - request.range.lowerBound), complete: true))
                }
                self.dataRequests.removeAll()
                
                for statusRequest in self.statusRequests.copyItems() {
                    statusRequest.0(.Local)
                }
                self.statusRequests.removeAll()
                
                self.storageBox.update(id: self.resourceId, size: size)
                
                self.completed(size)
            } else {
                assertionFailure()
            }
        }
    }
    
    func truncate(_ size: Int64) {
        assert(self.queue.isCurrent())
        
        let range: Range<Int64> = size ..< Int64.max
        
        self.fileMap.truncate(size)
        self.fileMap.serialize(manager: self.manager, to: self.metaPath)
        
        self.checkDataRequestsAfterFill(range: range)
    }
    
    func progressUpdated(_ progress: Float) {
        assert(self.queue.isCurrent())
        
        self.fileMap.progressUpdated(progress)
        self.updateStatuses()
    }
    
    func write(offset: Int64, data: Data, dataRange: Range<Int64>) {
        assert(self.queue.isCurrent())
        
        do {
            try self.fd.access { fd in
                let _ = fd.seek(position: offset)
                let written = data.withUnsafeBytes { rawBytes -> Int in
                    let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

                    return fd.write(bytes.advanced(by: Int(dataRange.lowerBound)), count: dataRange.count)
                }
                assert(written == dataRange.count)
            }
        } catch let e {
            postboxLog("MediaBoxPartialFile.write error: \(e)")
        }
        
        let range: Range<Int64> = offset ..< (offset + Int64(dataRange.count))
        self.fileMap.fill(range)
        self.fileMap.serialize(manager: self.manager, to: self.metaPath)
        
        self.storageBox.update(id: self.resourceId, size: self.fileMap.sum)
        
        self.checkDataRequestsAfterFill(range: range)
    }
    
    func checkDataRequestsAfterFill(range: Range<Int64>) {
        var removeIndices: [(Int, MediaBoxPartialFileDataRequest)] = []
        for (index, request) in self.dataRequests.copyItemsWithIndices() {
            if request.range.overlaps(range) {
                var maxValue = request.range.upperBound
                if let truncationSize = self.fileMap.truncationSize {
                    maxValue = truncationSize
                }
                if request.range.lowerBound > maxValue {
                    assertionFailure()
                    removeIndices.append((index, request))
                } else {
                    let intRange: Range<Int64> = request.range.lowerBound ..< min(maxValue, request.range.upperBound)
                    if self.fileMap.ranges.isSuperset(of: RangeSet<Int64>(intRange)) {
                        removeIndices.append((index, request))
                    }
                }
            }
        }
        if !removeIndices.isEmpty {
            for (index, request) in removeIndices {
                self.dataRequests.remove(index)
                var maxValue = request.range.upperBound
                if let truncationSize = self.fileMap.truncationSize, truncationSize < maxValue {
                    maxValue = truncationSize
                }
                request.completion(MediaResourceData(path: self.path, offset: request.range.lowerBound, size: maxValue - request.range.lowerBound, complete: true))
            }
        }
        
        var isCompleted = false
        if let truncationSize = self.fileMap.truncationSize, let _ = self.fileMap.contains(0 ..< truncationSize) {
            isCompleted = true
        }
        
        if isCompleted {
            for (_, completion) in self.missingRanges.clear() {
                completion()
            }
        } else {
            if let (updatedRanges, completions) = self.missingRanges.fill(range) {
                self.updateRequestRanges(updatedRanges, fetch: nil)
                completions.forEach({ $0() })
            }
        }
        
        if !self.rangeStatusRequests.isEmpty {
            let ranges = self.fileMap.ranges
            for (f, completed) in self.rangeStatusRequests.copyItems() {
                f(ranges)
                if isCompleted {
                    completed()
                }
            }
            if isCompleted {
                self.rangeStatusRequests.removeAll()
            }
        }
        
        self.updateStatuses()
        
        if isCompleted {
            for statusRequest in self.statusRequests.copyItems() {
                statusRequest.0(.Local)
            }
            self.statusRequests.removeAll()
            self.fd.sync()
            let linkResult = link(self.path, self.completePath)
            if linkResult != 0 {
                //assert(linkResult == 0)
            }
            self.completed(self.fileMap.sum)
        }
    }
    
    func read(range: Range<Int64>) -> Data? {
        assert(self.queue.isCurrent())
        
        if let actualRange = self.fileMap.contains(range) {
            do {
                var result: Data?
                try self.fd.access { fd in
                    let _ = fd.seek(position: Int64(actualRange.lowerBound))
                    var data = Data(count: actualRange.count)
                    let dataCount = data.count
                    let readBytes = data.withUnsafeMutableBytes { rawBytes -> Int in
                        let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: Int8.self)
                        return fd.read(bytes, dataCount)
                    }
                    if readBytes == data.count {
                        result = data
                    } else {
                        result = nil
                    }
                }
                return result
            } catch let e {
                postboxLog("MediaBoxPartialFile.read error: \(e)")
                return nil
            }
        } else {
            return nil
        }
    }
    
    func data(range: Range<Int64>, waitUntilAfterInitialFetch: Bool, next: @escaping (MediaResourceData) -> Void) -> Disposable {
        assert(self.queue.isCurrent())
        
        if let actualRange = self.fileMap.contains(range) {
            next(MediaResourceData(path: self.path, offset: actualRange.lowerBound, size: Int64(actualRange.count), complete: true))
            return EmptyDisposable
        }
        
        var waitingUntilAfterInitialFetch = false
        if waitUntilAfterInitialFetch && !self.processedAtLeastOneFetch {
            waitingUntilAfterInitialFetch = true
        } else {
            next(MediaResourceData(path: self.path, offset: range.lowerBound, size: 0, complete: false))
        }
        
        let index = self.dataRequests.add(MediaBoxPartialFileDataRequest(range: range, waitingUntilAfterInitialFetch: waitingUntilAfterInitialFetch, completion: { data in
            next(data)
        }))
        
        let queue = self.queue
        return ActionDisposable { [weak self] in
            queue.async {
                if let strongSelf = self {
                    strongSelf.dataRequests.remove(index)
                }
            }
        }
    }
    
    func fetched(range: Range<Int64>, priority: MediaBoxFetchPriority, fetch: @escaping (Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError>) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>, error: @escaping (MediaResourceDataFetchError) -> Void, completed: @escaping () -> Void) -> Disposable {
        assert(self.queue.isCurrent())
        
        if let _ = self.fileMap.contains(range) {
            completed()
            return EmptyDisposable
        }
        
        let (index, updatedRanges) = self.missingRanges.addRequest(fileMap: self.fileMap, range: range, priority: priority, error: error, completion: {
            completed()
        })
        if let updatedRanges = updatedRanges {
            self.updateRequestRanges(updatedRanges, fetch: fetch)
        }
        
        let queue = self.queue
        return ActionDisposable { [weak self] in
            queue.async {
                if let strongSelf = self {
                    if let updatedRanges = strongSelf.missingRanges.removeRequest(fileMap: strongSelf.fileMap, index: index) {
                        strongSelf.updateRequestRanges(updatedRanges, fetch: nil)
                    }
                }
            }
        }
    }
    
    func fetchedFullRange(fetch: @escaping (Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError>) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>, error: @escaping (MediaResourceDataFetchError) -> Void, completed: @escaping () -> Void) -> Disposable {
        let queue = self.queue
        let disposable = MetaDisposable()
        
        let index = self.fullRangeRequests.add(disposable)
        self.updateStatuses()
        
        disposable.set(self.fetched(range: 0 ..< Int64.max, priority: .default, fetch: fetch, error: { e in
            error(e)
        }, completed: { [weak self] in
            queue.async {
                if let strongSelf = self {
                    strongSelf.fullRangeRequests.remove(index)
                    if strongSelf.fullRangeRequests.isEmpty {
                        strongSelf.updateStatuses()
                    }
                }
                completed()
            }
        }))
        
        return ActionDisposable { [weak self] in
            queue.async {
                if let strongSelf = self {
                    strongSelf.fullRangeRequests.remove(index)
                    disposable.dispose()
                    if strongSelf.fullRangeRequests.isEmpty {
                        strongSelf.updateStatuses()
                    }
                }
            }
        }
    }
    
    func cancelFullRangeFetches() {
        self.fullRangeRequests.copyItems().forEach({ $0.dispose() })
        self.fullRangeRequests.removeAll()
        
        self.updateStatuses()
    }
    
    private func updateStatuses() {
        if !self.statusRequests.isEmpty {
            for (f, size) in self.statusRequests.copyItems() {
                let status = self.immediateStatus(size: size)
                f(status)
            }
        }
    }
    
    func rangeStatus(next: @escaping (RangeSet<Int64>) -> Void, completed: @escaping () -> Void) -> Disposable {
        assert(self.queue.isCurrent())
        
        next(self.fileMap.ranges)
        if let truncationSize = self.fileMap.truncationSize, let _ = self.fileMap.contains(0 ..< truncationSize) {
            completed()
            return EmptyDisposable
        }
        
        let index = self.rangeStatusRequests.add((next, completed))
        
        let queue = self.queue
        return ActionDisposable { [weak self] in
            queue.async {
                if let strongSelf = self {
                    strongSelf.rangeStatusRequests.remove(index)
                }
            }
        }
    }
    
    private func immediateStatus(size: Int64?) -> MediaResourceStatus {
        let status: MediaResourceStatus
        if self.fullRangeRequests.isEmpty && self.currentFetch == nil {
            if let truncationSize = self.fileMap.truncationSize, self.fileMap.sum == truncationSize {
                status = .Local
            } else {
                let progress: Float
                if let truncationSize = self.fileMap.truncationSize, truncationSize != 0 {
                    progress = Float(self.fileMap.sum) / Float(truncationSize)
                } else if let size = size {
                    progress = Float(self.fileMap.sum) / Float(size)
                } else {
                    progress = self.fileMap.progress ?? 0.0
                }
                status = .Remote(progress: progress)
            }
        } else {
            let progress: Float
            if let truncationSize = self.fileMap.truncationSize, truncationSize != 0 {
                progress = Float(self.fileMap.sum) / Float(truncationSize)
            } else if let size = size {
                progress = Float(self.fileMap.sum) / Float(size)
            } else {
                progress = self.fileMap.progress ?? 0.0
            }
            status = .Fetching(isActive: true, progress: progress)
        }
        return status
    }
    
    func status(next: @escaping (MediaResourceStatus) -> Void, completed: @escaping () -> Void, size: Int64?) -> Disposable {
        let index = self.statusRequests.add((next, size))
        
        let value = self.immediateStatus(size: size)
        next(value)
        if case .Local = value {
            completed()
            return EmptyDisposable
        } else {
            let queue = self.queue
            return ActionDisposable { [weak self] in
                queue.async {
                    if let strongSelf = self {
                        strongSelf.statusRequests.remove(index)
                    }
                }
            }
        }
    }
    
    private func updateRequestRanges(_ intervals: [(Range<Int64>, MediaBoxFetchPriority)], fetch: ((Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError>) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>)?) {
        assert(self.queue.isCurrent())
        
        #if DEBUG
        for interval in intervals {
            assert(!interval.0.isEmpty)
        }
        #endif
        if intervals.isEmpty {
            if let (_, disposable) = self.currentFetch {
                self.currentFetch = nil
                self.updateStatuses()
                disposable.dispose()
            }
        } else {
            if let (promise, _) = self.currentFetch {
                promise.set(.single(intervals))
            } else if let fetch = fetch {
                let promise = Promise<[(Range<Int64>, MediaBoxFetchPriority)]>()
                let disposable = MetaDisposable()
                self.currentFetch = (promise, disposable)
                self.updateStatuses()
                disposable.set((fetch(promise.get())
                |> deliverOn(self.queue)).start(next: { [weak self] data in
                    if let strongSelf = self {
                        switch data {
                            case .reset:
                                if !strongSelf.fileMap.ranges.isEmpty {
                                    strongSelf.reset()
                                }
                            case let .resourceSizeUpdated(size):
                                strongSelf.truncate(size)
                            case let .dataPart(resourceOffset, data, range, complete):
                                if !data.isEmpty {
                                    strongSelf.write(offset: resourceOffset, data: data, dataRange: range)
                                }
                                if complete {
                                    if let maxOffset = strongSelf.fileMap.ranges.ranges.reversed().first?.upperBound {
                                        let maxValue = max(resourceOffset + Int64(range.count), Int64(maxOffset))
                                        strongSelf.truncate(maxValue)
                                    }
                                }
                            case let .replaceHeader(data, range):
                                strongSelf.write(offset: 0, data: data, dataRange: range)
                            case let .moveLocalFile(path):
                                strongSelf.moveLocalFile(tempPath: path)
                            case let .moveTempFile(file):
                                strongSelf.moveLocalFile(tempPath: file.path)
                                TempBox.shared.dispose(file)
                            case let .copyLocalItem(item):
                                strongSelf.copyLocalItem(item)
                            case let .progressUpdated(progress):
                                strongSelf.progressUpdated(progress)
                        }
                        if !strongSelf.processedAtLeastOneFetch {
                            strongSelf.processedAtLeastOneFetch = true
                            for request in strongSelf.dataRequests.copyItems() {
                                if request.waitingUntilAfterInitialFetch {
                                    request.waitingUntilAfterInitialFetch = false
                                    
                                    if let actualRange = strongSelf.fileMap.contains(request.range) {
                                        request.completion(MediaResourceData(path: strongSelf.path, offset: actualRange.lowerBound, size: Int64(actualRange.count), complete: true))
                                    } else {
                                        request.completion(MediaResourceData(path: strongSelf.path, offset: request.range.lowerBound, size: 0, complete: false))
                                    }
                                }
                            }
                        }
                    }
                }, error: { [weak self] e in
                    guard let strongSelf = self else {
                        return
                    }
                    for (error, _) in strongSelf.missingRanges.clear() {
                        error(e)
                    }
                }))
                promise.set(.single(intervals))
            }
        }
    }
}

private final class MediaBoxFileMissingRange {
    var range: Range<Int64>
    let priority: MediaBoxFetchPriority
    var remainingRanges: RangeSet<Int64>
    let error: (MediaResourceDataFetchError) -> Void
    let completion: () -> Void
    
    init(range: Range<Int64>, priority: MediaBoxFetchPriority, error: @escaping (MediaResourceDataFetchError) -> Void, completion: @escaping () -> Void) {
        self.range = range
        self.priority = priority
        self.remainingRanges = RangeSet<Int64>(range)
        self.error = error
        self.completion = completion
    }
}

private final class MediaBoxFileMissingRanges {
    private var requestedRanges = Bag<MediaBoxFileMissingRange>()
    
    private var missingRangesFlattened = RangeSet<Int64>()
    private var missingRangesByPriority: [MediaBoxFetchPriority: RangeSet<Int64>] = [:]
    
    func clear() -> [((MediaResourceDataFetchError) -> Void, () -> Void)] {
        let errorsAndCompletions = self.requestedRanges.copyItems().map({ ($0.error, $0.completion) })
        self.requestedRanges.removeAll()
        return errorsAndCompletions
    }
    
    func reset(fileMap: MediaBoxFileMap) -> [(Range<Int64>, MediaBoxFetchPriority)]? {
        return self.update(fileMap: fileMap)
    }
    
    private func missingRequestedIntervals() -> [(Range<Int64>, MediaBoxFetchPriority)] {
        var intervalsByPriority: [MediaBoxFetchPriority: RangeSet<Int64>] = [:]
        var remainingIntervals = RangeSet<Int64>()
        for item in self.requestedRanges.copyItems() {
            var requestedInterval = RangeSet<Int64>(item.range)
            requestedInterval.formIntersection(self.missingRangesFlattened)
            if !requestedInterval.isEmpty {
                if intervalsByPriority[item.priority] == nil {
                    intervalsByPriority[item.priority] = RangeSet<Int64>()
                }
                intervalsByPriority[item.priority]?.formUnion(requestedInterval)
                remainingIntervals.formUnion(requestedInterval)
            }
        }
        
        var result: [(Range<Int64>, MediaBoxFetchPriority)] = []
        
        for priority in intervalsByPriority.keys.sorted(by: { $0.rawValue > $1.rawValue }) {
            let currentIntervals = intervalsByPriority[priority]!.intersection(remainingIntervals)
            remainingIntervals.subtract(currentIntervals)
            for range in currentIntervals.ranges {
                if !range.isEmpty {
                    result.append((range, priority))
                }
            }
        }
        
        return result
    }
    
    func fill(_ range: Range<Int64>) -> ([(Range<Int64>, MediaBoxFetchPriority)], [() -> Void])? {
        if self.missingRangesFlattened.intersects(range) {
            self.missingRangesFlattened.remove(contentsOf: range)
            for priority in self.missingRangesByPriority.keys {
                self.missingRangesByPriority[priority]!.remove(contentsOf: range)
            }
            
            var completions: [() -> Void] = []
            for (index, item) in self.requestedRanges.copyItemsWithIndices() {
                if item.range.overlaps(range) {
                    item.remainingRanges.remove(contentsOf: range)
                    if item.remainingRanges.isEmpty {
                        self.requestedRanges.remove(index)
                        completions.append(item.completion)
                    }
                }
            }
            
            return (self.missingRequestedIntervals(), completions)
        } else {
            return nil
        }
    }
    
    func addRequest(fileMap: MediaBoxFileMap, range: Range<Int64>, priority: MediaBoxFetchPriority, error: @escaping (MediaResourceDataFetchError) -> Void, completion: @escaping () -> Void) -> (Int, [(Range<Int64>, MediaBoxFetchPriority)]?) {
        let index = self.requestedRanges.add(MediaBoxFileMissingRange(range: range, priority: priority, error: error, completion: completion))
        
        return (index, self.update(fileMap: fileMap))
    }
    
    func removeRequest(fileMap: MediaBoxFileMap, index: Int) -> [(Range<Int64>, MediaBoxFetchPriority)]? {
        self.requestedRanges.remove(index)
        return self.update(fileMap: fileMap)
    }
    
    private func update(fileMap: MediaBoxFileMap) -> [(Range<Int64>, MediaBoxFetchPriority)]? {
        var byPriority: [MediaBoxFetchPriority: RangeSet<Int64>] = [:]
        var flattened = RangeSet<Int64>()
        for item in self.requestedRanges.copyItems() {
            let intRange: Range<Int64> = item.range
            if byPriority[item.priority] == nil {
                byPriority[item.priority] = RangeSet<Int64>()
            }
            byPriority[item.priority]!.insert(contentsOf: intRange)
            flattened.insert(contentsOf: intRange)
        }
        for priority in byPriority.keys {
            byPriority[priority]!.subtract(fileMap.ranges)
        }
        flattened.subtract(fileMap.ranges)
        if byPriority != self.missingRangesByPriority {
            self.missingRangesByPriority = byPriority
            self.missingRangesFlattened = flattened
            
            return self.missingRequestedIntervals()
        }
        return nil
    }
}
