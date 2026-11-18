// kbflash: flash the MacBook keyboard backlight to get your attention, then put it back.
// usage: kbflash [flashes=3] [on_ms=150] [off_ms=150]
// Lit keyboard  -> dips off and back to your level.
// Dark/dim one  -> pulses off/100%, then back to your level.
#import <Foundation/Foundation.h>
#include <sys/file.h>
#include <fcntl.h>

@interface KeyboardBrightnessClient : NSObject // private, CoreBrightness.framework
- (NSArray *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)k;
- (BOOL)setBrightness:(float)b forKeyboard:(unsigned long long)k;
- (BOOL)setBrightness:(float)b fadeSpeed:(int)ms commit:(BOOL)c forKeyboard:(unsigned long long)k;
@end

// ponytail: calibration knob. At or above this your own level is visible enough to dip from; below it we pulse to 100%.
static const float BRIGHT = 0.5f;

int main(int argc, const char **argv) { @autoreleasepool {
  int n = argc > 1 ? atoi(argv[1]) : 3, on = argc > 2 ? atoi(argv[2]) : 150, off = argc > 3 ? atoi(argv[3]) : 150;

  // one flasher at a time: a second one would read the mid-flash "off" as the level to restore
  int lock = open("/tmp/kbflash.lock", O_CREAT | O_RDWR, 0666);
  if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) return 0;

  KeyboardBrightnessClient *c = [KeyboardBrightnessClient new];
  NSArray *ids = [c copyKeyboardBacklightIDs];
  if (!ids.count) { fprintf(stderr, "kbflash: no keyboard backlight\n"); return 1; }
  unsigned long long k = [ids[0] unsignedLongLongValue];

  // commit:NO everywhere, so a flash never becomes your saved brightness
  BOOL fade = [c respondsToSelector:@selector(setBrightness:fadeSpeed:commit:forKeyboard:)];
  #define SET(v) (fade ? [c setBrightness:(v) fadeSpeed:0 commit:NO forKeyboard:k] : [c setBrightness:(v) forKeyboard:k])

  float orig = [c brightnessForKeyboard:k];
  float hi = orig >= BRIGHT ? orig : 1.0f;
  for (int i = 0; i < n; i++) {
    SET(0.0f); usleep(off * 1000);
    SET(hi);   usleep(on * 1000);
  }
  if (hi != orig) { SET(0.0f); usleep(off * 1000); }
  SET(orig);
  return 0;
}}
