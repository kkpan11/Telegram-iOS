import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi
import MtProtoKit

public struct StarsRevenueStats: Equatable {
    public struct Balances: Equatable {
        public let currentBalance: Int64
        public let availableBalance: Int64
        public let overallRevenue: Int64
        public let withdrawEnabled: Bool
    }
    
    public let revenueGraph: StatsGraph
    public let balances: Balances
    public let usdRate: Double
    init(revenueGraph: StatsGraph, balances: Balances, usdRate: Double) {
        self.revenueGraph = revenueGraph
        self.balances = balances
        self.usdRate = usdRate
    }
    
    public static func == (lhs: StarsRevenueStats, rhs: StarsRevenueStats) -> Bool {
        if lhs.revenueGraph != rhs.revenueGraph {
            return false
        }
        if lhs.balances != rhs.balances {
            return false
        }
        if lhs.usdRate != rhs.usdRate {
            return false
        }
        return true
    }
}

public extension StarsRevenueStats {
    func withUpdated(balances: StarsRevenueStats.Balances) -> StarsRevenueStats {
        return StarsRevenueStats(
            revenueGraph: self.revenueGraph,
            balances: balances,
            usdRate: self.usdRate
        )
    }
}

extension StarsRevenueStats {
    init(apiStarsRevenueStats: Api.payments.StarsRevenueStats, peerId: PeerId) {
        switch apiStarsRevenueStats {
        case let .starsRevenueStats(revenueGraph, balances, usdRate):
            self.init(revenueGraph: StatsGraph(apiStatsGraph: revenueGraph), balances: StarsRevenueStats.Balances(apiStarsRevenueStatus: balances), usdRate: usdRate)
        }
    }
}

extension StarsRevenueStats.Balances {
    init(apiStarsRevenueStatus: Api.StarsRevenueStatus) {
        switch apiStarsRevenueStatus {
        case let .starsRevenueStatus(flags, currentBalance, availableBalance, overallRevenue):
            self.init(currentBalance: currentBalance, availableBalance: availableBalance, overallRevenue: overallRevenue, withdrawEnabled: ((flags & (1 << 0)) != 0))
        }
    }
}

public struct StarsRevenueStatsContextState: Equatable {
    public var stats: StarsRevenueStats?
}

private func requestStarsRevenueStats(postbox: Postbox, network: Network, peerId: PeerId, dark: Bool = false) -> Signal<StarsRevenueStats?, NoError> {
    return postbox.transaction { transaction -> Peer? in
        if let peer = transaction.getPeer(peerId) {
            return peer
        }
        return nil
    } |> mapToSignal { peer -> Signal<StarsRevenueStats?, NoError> in
        guard let peer, let inputPeer = apiInputPeer(peer) else {
            return .never()
        }
        
        var flags: Int32 = 0
        if dark {
            flags |= (1 << 1)
        }
        
        return network.request(Api.functions.payments.getStarsRevenueStats(flags: flags, peer: inputPeer))
        |> map { result -> StarsRevenueStats? in
            return StarsRevenueStats(apiStarsRevenueStats: result, peerId: peerId)
        }
        |> retryRequest
    }
}

private final class StarsRevenueStatsContextImpl {
    private let account: Account
    private let peerId: PeerId
    
    private var _state: StarsRevenueStatsContextState {
        didSet {
            if self._state != oldValue {
                self._statePromise.set(.single(self._state))
            }
        }
    }
    private let _statePromise = Promise<StarsRevenueStatsContextState>()
    var state: Signal<StarsRevenueStatsContextState, NoError> {
        return self._statePromise.get()
    }
    
    private let disposable = MetaDisposable()
    
    init(account: Account, peerId: PeerId) {
        assert(Queue.mainQueue().isCurrent())
        
        self.account = account
        self.peerId = peerId
        self._state = StarsRevenueStatsContextState(stats: nil)
        self._statePromise.set(.single(self._state))
        
        self.load()
    }
    
    deinit {
        assert(Queue.mainQueue().isCurrent())
        self.disposable.dispose()
    }
    
    fileprivate func load() {
        assert(Queue.mainQueue().isCurrent())
        
        let account = self.account
        let peerId = self.peerId
        let signal = requestStarsRevenueStats(postbox: self.account.postbox, network: self.account.network, peerId: self.peerId)
        |> mapToSignal { initial -> Signal<StarsRevenueStats?, NoError> in
            guard let initial else {
                return .single(nil)
            }
            return .single(initial)
            |> then(
                account.stateManager.updatedStarsRevenueStatus()
                |> mapToSignal { updates in
                    if let balances = updates[peerId] {
                        return .single(initial.withUpdated(balances: balances))
                    }
                    return .complete()
                }
            )
        }
        
        self.disposable.set((signal
        |> deliverOnMainQueue).start(next: { [weak self] stats in
            if let strongSelf = self {
                strongSelf._state = StarsRevenueStatsContextState(stats: stats)
                strongSelf._statePromise.set(.single(strongSelf._state))
            }
        }))
    }
        
    func loadDetailedGraph(_ graph: StatsGraph, x: Int64) -> Signal<StatsGraph?, NoError> {
        if let token = graph.token {
            return requestGraph(postbox: self.account.postbox, network: self.account.network, peerId: self.peerId, token: token, x: x)
        } else {
            return .single(nil)
        }
    }
}

public final class StarsRevenueStatsContext {
    private let impl: QueueLocalObject<StarsRevenueStatsContextImpl>
    
    public var state: Signal<StarsRevenueStatsContextState, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.state.start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
    
    public init(account: Account, peerId: PeerId) {
        self.impl = QueueLocalObject(queue: Queue.mainQueue(), generate: {
            return StarsRevenueStatsContextImpl(account: account, peerId: peerId)
        })
    }
    
    public func reload() {
        self.impl.with { impl in
            impl.load()
        }
    }
            
    public func loadDetailedGraph(_ graph: StatsGraph, x: Int64) -> Signal<StatsGraph?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.loadDetailedGraph(graph, x: x).start(next: { value in
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
}

public enum RequestStarsRevenueWithdrawalError : Equatable {
    case generic
    case twoStepAuthMissing
    case twoStepAuthTooFresh(Int32)
    case authSessionTooFresh(Int32)
    case limitExceeded
    case requestPassword
    case invalidPassword
}

func _internal_checkStarsRevenueWithdrawalAvailability(account: Account) -> Signal<Never, RequestStarsRevenueWithdrawalError> {
    return account.network.request(Api.functions.payments.getStarsRevenueWithdrawalUrl(peer: .inputPeerEmpty, stars: 0, password: .inputCheckPasswordEmpty))
    |> mapError { error -> RequestStarsRevenueWithdrawalError in
        if error.errorDescription == "PASSWORD_HASH_INVALID" {
            return .requestPassword
        } else if error.errorDescription == "PASSWORD_MISSING" {
            return .twoStepAuthMissing
        } else if error.errorDescription.hasPrefix("PASSWORD_TOO_FRESH_") {
            let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "PASSWORD_TOO_FRESH_".count)...])
            if let value = Int32(timeout) {
                return .twoStepAuthTooFresh(value)
            }
        } else if error.errorDescription.hasPrefix("SESSION_TOO_FRESH_") {
            let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "SESSION_TOO_FRESH_".count)...])
            if let value = Int32(timeout) {
                return .authSessionTooFresh(value)
            }
        }
        return .generic
    }
    |> ignoreValues
}

func _internal_requestStarsRevenueWithdrawalUrl(account: Account, peerId: PeerId, amount: Int64, password: String) -> Signal<String, RequestStarsRevenueWithdrawalError> {
    guard !password.isEmpty else {
        return .fail(.invalidPassword)
    }
    
    return account.postbox.transaction { transaction -> Signal<String, RequestStarsRevenueWithdrawalError> in
        guard let peer = transaction.getPeer(peerId), let inputPeer = apiInputPeer(peer) else {
            return .fail(.generic)
        }
            
        let checkPassword = _internal_twoStepAuthData(account.network)
        |> mapError { error -> RequestStarsRevenueWithdrawalError in
            if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                return .limitExceeded
            } else {
                return .generic
            }
        }
        |> mapToSignal { authData -> Signal<Api.InputCheckPasswordSRP, RequestStarsRevenueWithdrawalError> in
            if let currentPasswordDerivation = authData.currentPasswordDerivation, let srpSessionData = authData.srpSessionData {
                guard let kdfResult = passwordKDF(encryptionProvider: account.network.encryptionProvider, password: password, derivation: currentPasswordDerivation, srpSessionData: srpSessionData) else {
                    return .fail(.generic)
                }
                return .single(.inputCheckPasswordSRP(srpId: kdfResult.id, A: Buffer(data: kdfResult.A), M1: Buffer(data: kdfResult.M1)))
            } else {
                return .fail(.twoStepAuthMissing)
            }
        }
        
        return checkPassword
        |> mapToSignal { password -> Signal<String, RequestStarsRevenueWithdrawalError> in
            return account.network.request(Api.functions.payments.getStarsRevenueWithdrawalUrl(peer: inputPeer, stars: amount, password: password), automaticFloodWait: false)
            |> mapError { error -> RequestStarsRevenueWithdrawalError in
                if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                    return .limitExceeded
                } else if error.errorDescription == "PASSWORD_HASH_INVALID" {
                    return .invalidPassword
                } else if error.errorDescription == "PASSWORD_MISSING" {
                    return .twoStepAuthMissing
                } else if error.errorDescription.hasPrefix("PASSWORD_TOO_FRESH_") {
                    let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "PASSWORD_TOO_FRESH_".count)...])
                    if let value = Int32(timeout) {
                        return .twoStepAuthTooFresh(value)
                    }
                } else if error.errorDescription.hasPrefix("SESSION_TOO_FRESH_") {
                    let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "SESSION_TOO_FRESH_".count)...])
                    if let value = Int32(timeout) {
                        return .authSessionTooFresh(value)
                    }
                }
                return .generic
            }
            |> map { result -> String in
                switch result {
                case let .starsRevenueWithdrawalUrl(url):
                    return url
                }
            }
        }
    }
    |> mapError { _ -> RequestStarsRevenueWithdrawalError in }
    |> switchToLatest
}