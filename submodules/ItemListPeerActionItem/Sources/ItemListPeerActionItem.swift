import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils

public enum ItemListPeerActionItemHeight {
    case generic
    case compactPeerList
    case peerList
}

public enum ItemListPeerActionItemColor {
    case accent
    case destructive
    case disabled
}

public class ItemListPeerActionItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let style: ItemListStyle
    let icon: UIImage?
    let iconSignal: Signal<UIImage?, NoError>?
    let title: String
    let additionalBadgeIcon: UIImage?
    public let alwaysPlain: Bool
    let hasSeparator: Bool
    let editing: Bool
    let height: ItemListPeerActionItemHeight
    let color: ItemListPeerActionItemColor
    let noInsets: Bool
    public let sectionId: ItemListSectionId
    public let action: (() -> Void)?
    
    public init(presentationData: ItemListPresentationData, style: ItemListStyle = .blocks, icon: UIImage?, iconSignal: Signal<UIImage?, NoError>? = nil, title: String, additionalBadgeIcon: UIImage? = nil, alwaysPlain: Bool = false, hasSeparator: Bool = true, sectionId: ItemListSectionId, height: ItemListPeerActionItemHeight = .peerList, color: ItemListPeerActionItemColor = .accent, noInsets: Bool = false, editing: Bool = false, action: (() -> Void)?) {
        self.presentationData = presentationData
        self.style = style
        self.icon = icon
        self.iconSignal = iconSignal
        self.title = title
        self.additionalBadgeIcon = additionalBadgeIcon
        self.alwaysPlain = alwaysPlain
        self.hasSeparator = hasSeparator
        self.editing = editing
        self.height = height
        self.noInsets = noInsets
        self.color = color
        self.sectionId = sectionId
        self.action = action
    }
    
    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ItemListPeerActionItemNode()
            var neighbors = itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem)
            if self.alwaysPlain {
                neighbors.top = .sameSection(alwaysPlain: false)
            }
            if self.alwaysPlain {
                neighbors.bottom = .sameSection(alwaysPlain: false)
            }
            let (layout, apply) = node.asyncLayout()(self, params, neighbors)
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(false) })
                })
            }
        }
    }
    
    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? ItemListPeerActionItemNode {
                let makeLayout = nodeValue.asyncLayout()
                
                var animated = true
                if case .None = animation {
                    animated = false
                }
                
                async {
                    var neighbors = itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem)
                    if self.alwaysPlain {
                        neighbors.top = .sameSection(alwaysPlain: false)
                    }
                    if self.alwaysPlain {
                        neighbors.bottom = .sameSection(alwaysPlain: false)
                    }
                    let (layout, apply) = makeLayout(self, params, neighbors)
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animated)
                        })
                    }
                }
            }
        }
    }
    
    public var selectable: Bool {
        return self.action != nil
    }
    
    public func selected(listView: ListView){
        listView.clearHighlightAnimated(true)
        self.action?()
    }
}

public final class ItemListPeerActionItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    private let maskNode: ASImageNode
    
    private let iconNode: ASImageNode
    private let titleNode: TextNode
    private var additionalLabelBadgeNode: ASImageNode?
    
    private let activateArea: AccessibilityAreaNode
    
    private var item: ItemListPeerActionItem?
    
    private let iconDisposable = MetaDisposable()
    
    public init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        
        self.maskNode = ASImageNode()
        
        self.iconNode = ASImageNode()
        self.iconNode.isLayerBacked = true
        self.iconNode.displayWithoutProcessing = true
        self.iconNode.displaysAsynchronously = false
        
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .left
        self.titleNode.contentsScale = UIScreen.main.scale
        
        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true
        
        self.activateArea = AccessibilityAreaNode()
        
        super.init(layerBacked: false, dynamicBounce: false)
        
        self.addSubnode(self.iconNode)
        self.addSubnode(self.titleNode)
        
        self.addSubnode(self.activateArea)
    }
    
    deinit {
        self.iconDisposable.dispose()
    }
    
    public func asyncLayout() -> (_ item: ItemListPeerActionItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, (Bool) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        
        let currentItem = self.item
        
        return { item, params, neighbors in
            var updatedTheme: PresentationTheme?
            
            let titleFont = Font.regular(item.presentationData.fontSize.itemListBaseFontSize)
            
            if currentItem?.presentationData.theme !== item.presentationData.theme {
                updatedTheme = item.presentationData.theme
            }
            let leftInset: CGFloat
            let iconOffset: CGFloat
            let verticalInset: CGFloat
            let verticalOffset: CGFloat
            switch item.height {
                case .generic:
                    iconOffset = 1.0
                    verticalInset = 12.0
                    verticalOffset = 0.0
                    leftInset = (item.icon == nil && item.iconSignal == nil ? 16.0 : 59.0) + params.leftInset
                case .peerList:
                    iconOffset = 3.0
                    verticalInset = 14.0
                    verticalOffset = 0.0
                    leftInset = 65.0 + params.leftInset
                case .compactPeerList:
                    iconOffset = 3.0
                    verticalInset = 11.0
                    verticalOffset = 0.0
                    leftInset = 65.0 + params.leftInset
            }
            
            let editingOffset: CGFloat = (item.editing ? 38.0 : 0.0)
            
            let textColor: UIColor
            switch item.color {
                case .accent:
                    textColor = item.presentationData.theme.list.itemAccentColor
                case .destructive:
                    textColor = item.presentationData.theme.list.itemDestructiveColor
                case .disabled:
                    textColor = item.presentationData.theme.list.itemDisabledTextColor
            }
            
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: textColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - leftInset - editingOffset, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
            
            let separatorHeight = UIScreenPixel
            
            var insets = itemListNeighborsGroupedInsets(neighbors, params)
            if item.noInsets {
                insets.top = 0.0
                insets.bottom = 0.0
            }
            let contentSize = CGSize(width: params.width, height: titleLayout.size.height + verticalInset * 2.0)
            
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size
            
            return (layout, { [weak self] animated in
                if let strongSelf = self {
                    strongSelf.item = item
                    
                    strongSelf.activateArea.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: params.width - params.leftInset - params.rightInset, height: layout.contentSize.height))
                    strongSelf.activateArea.accessibilityLabel = item.title
                    
                    if let _ = updatedTheme {
                        switch item.style {
                        case .blocks:
                            strongSelf.topStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                            strongSelf.bottomStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                            strongSelf.backgroundNode.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
                            strongSelf.highlightedBackgroundNode.backgroundColor = item.presentationData.theme.list.itemHighlightedBackgroundColor
                        case .plain:
                            strongSelf.topStripeNode.backgroundColor = item.presentationData.theme.list.itemPlainSeparatorColor
                            strongSelf.bottomStripeNode.backgroundColor = item.presentationData.theme.list.itemPlainSeparatorColor
                            strongSelf.backgroundNode.backgroundColor = item.presentationData.theme.list.plainBackgroundColor
                            strongSelf.highlightedBackgroundNode.backgroundColor = item.presentationData.theme.list.itemHighlightedBackgroundColor
                        }
                    }
                    
                    let _ = titleApply()
                    
                    let transition: ContainedViewLayoutTransition
                    if animated {
                        transition = ContainedViewLayoutTransition.animated(duration: 0.4, curve: .spring)
                    } else {
                        transition = .immediate
                    }
                    
                    strongSelf.iconNode.image = item.icon
                    if let image = item.icon {
                        transition.updateFrame(node: strongSelf.iconNode, frame: CGRect(origin: CGPoint(x: params.leftInset + editingOffset + floor((leftInset - params.leftInset - image.size.width) / 2.0) + iconOffset, y: floor((contentSize.height - image.size.height) / 2.0)), size: image.size))
                    } else if let iconSignal = item.iconSignal {
                        let imageSize = CGSize(width: 28.0, height: 28.0)
                        strongSelf.iconDisposable.set((iconSignal
                        |> deliverOnMainQueue).start(next: { [weak self] image in
                            if let strongSelf = self, let image {
                                strongSelf.iconNode.image = image
                            }
                        }))
                        transition.updateFrame(node: strongSelf.iconNode, frame: CGRect(origin: CGPoint(x: params.leftInset + editingOffset + floor((leftInset - params.leftInset - imageSize.width) / 2.0) + iconOffset, y: floor((contentSize.height - imageSize.height) / 2.0)), size: imageSize))
                    }
                    
                    switch item.style {
                    case .plain:
                        if strongSelf.backgroundNode.supernode != nil {
                            strongSelf.backgroundNode.removeFromSupernode()
                        }
                        if strongSelf.topStripeNode.supernode != nil {
                            strongSelf.topStripeNode.removeFromSupernode()
                        }
                        if strongSelf.bottomStripeNode.supernode == nil {
                            strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 0)
                        }
                        if strongSelf.maskNode.supernode != nil {
                            strongSelf.maskNode.removeFromSupernode()
                        }
                        strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: leftInset, y: contentSize.height - separatorHeight), size: CGSize(width: params.width - leftInset, height: separatorHeight))
                    case .blocks:
                        if strongSelf.backgroundNode.supernode == nil {
                            strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                        }
                        if strongSelf.topStripeNode.supernode == nil {
                            strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                        }
                        if strongSelf.bottomStripeNode.supernode == nil {
                            strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                        }
                        if strongSelf.maskNode.supernode == nil {
                            strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                        }
                        
                        let hasCorners = itemListHasRoundedBlockLayout(params)
                        var hasTopCorners = false
                        var hasBottomCorners = false
                        switch neighbors.top {
                            case .sameSection(false):
                                strongSelf.topStripeNode.isHidden = true
                            default:
                                hasTopCorners = true
                                strongSelf.topStripeNode.isHidden = hasCorners
                        }
                        
                        let bottomStripeInset: CGFloat
                        let bottomStripeOffset: CGFloat
                        switch neighbors.bottom {
                            case .sameSection(false):
                                bottomStripeInset = leftInset + editingOffset
                                bottomStripeOffset = -separatorHeight
                                strongSelf.bottomStripeNode.isHidden = !item.hasSeparator
                            default:
                                bottomStripeInset = 0.0
                                bottomStripeOffset = 0.0
                                hasBottomCorners = true
                                strongSelf.bottomStripeNode.isHidden = hasCorners || !item.hasSeparator
                        }
                            
                        strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.presentationData.theme, top: hasTopCorners, bottom: hasBottomCorners) : nil
                        
                        strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                        strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                        strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                        transition.updateFrame(node: strongSelf.bottomStripeNode, frame: CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: layoutSize.width - bottomStripeInset, height: separatorHeight)))
                    }
                    
                    let titleFrame = CGRect(origin: CGPoint(x: leftInset + editingOffset, y: verticalInset + verticalOffset), size: titleLayout.size)
                    transition.updateFrame(node: strongSelf.titleNode, frame: titleFrame)
                    
                    strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -UIScreenPixel), size: CGSize(width: params.width, height: layout.contentSize.height + UIScreenPixel + UIScreenPixel))
                    
                    if let additionalBadgeIcon = item.additionalBadgeIcon {
                        let additionalLabelBadgeNode: ASImageNode
                        if let current = strongSelf.additionalLabelBadgeNode {
                            additionalLabelBadgeNode = current
                        } else {
                            additionalLabelBadgeNode = ASImageNode()
                            additionalLabelBadgeNode.isUserInteractionEnabled = false
                            strongSelf.additionalLabelBadgeNode = additionalLabelBadgeNode
                            strongSelf.addSubnode(additionalLabelBadgeNode)
                        }
                        additionalLabelBadgeNode.image = additionalBadgeIcon
                        
                        let additionalLabelSize = additionalBadgeIcon.size
                        additionalLabelBadgeNode.frame = CGRect(origin: CGPoint(x: titleFrame.maxX + 6.0, y: floor((contentSize.height - additionalLabelSize.height) / 2.0)), size: additionalLabelSize)
                    } else {
                        if let additionalLabelBadgeNode = strongSelf.additionalLabelBadgeNode {
                            strongSelf.additionalLabelBadgeNode = nil
                            additionalLabelBadgeNode.removeFromSupernode()
                        }
                    }
                }
            })
        }
    }
    
    public override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        
        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                var anchorNode: ASDisplayNode?
                if self.bottomStripeNode.supernode != nil {
                    anchorNode = self.bottomStripeNode
                } else if self.topStripeNode.supernode != nil {
                    anchorNode = self.topStripeNode
                } else if self.backgroundNode.supernode != nil {
                    anchorNode = self.backgroundNode
                }
                if let anchorNode = anchorNode {
                    self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: anchorNode)
                } else {
                    self.addSubnode(self.highlightedBackgroundNode)
                }
            }
        } else {
            if self.highlightedBackgroundNode.supernode != nil {
                if animated {
                    self.highlightedBackgroundNode.layer.animateAlpha(from: self.highlightedBackgroundNode.alpha, to: 0.0, duration: 0.4, completion: { [weak self] completed in
                        if let strongSelf = self {
                            if completed {
                                strongSelf.highlightedBackgroundNode.removeFromSupernode()
                            }
                        }
                        })
                    self.highlightedBackgroundNode.alpha = 0.0
                } else {
                    self.highlightedBackgroundNode.removeFromSupernode()
                }
            }
        }
    }
    
    public override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }
    
    public override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
