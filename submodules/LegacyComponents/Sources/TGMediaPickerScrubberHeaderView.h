#import <UIKit/UIKit.h>

#import "TGMediaPickerGalleryVideoScrubber.h"

@interface TGMediaPickerScrubberHeaderView : UIView

@property (nonatomic, assign) UIEdgeInsets safeAreaInset;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) TGMediaPickerGalleryVideoScrubber *scrubberView;
@property (nonatomic, strong) TGMediaPickerGalleryVideoScrubber *coverScrubberView;

@end
