// kbflash: flash a MacBook's keyboard backlight to get your attention, then put it back.
//
//   kbflash [pattern]                  play a pattern (default: done)
//   kbflash --until-back SECS [pattern] repeat every SECS until you touch the keyboard/trackpad
//   kbflash [pattern] -- cmd args...   run cmd, then flash (done/error by exit status unless pattern given)
//   kbflash --list                     show patterns
//
// A pattern is a name from ~/.config/kbflash/patterns (or a built-in), or written out:
//   "off/120 on/120 x3"   step = LEVEL/MS, xN repeats the steps since the last xN, ~ fades into a step
//   LEVEL: on | off | me (your level) | 0-100 (percent)
//   "on" is your level if the keyboard is lit, 100% if it's dark, so flashes always show.
//
// Lit, dark or idle-dimmed, it ends on your level. In a bright room (macOS holding it off) it does nothing.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <spawn.h>
#include <signal.h>

static volatile sig_atomic_t stopping; // set by SIGTERM/INT/HUP: cut the flash short, but still put your level back
static void onSignal(int sig) { (void)sig; stopping = 1; }

extern char **environ;

@interface KeyboardBrightnessClient : NSObject // private, CoreBrightness.framework
- (NSArray *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)k;
- (BOOL)setBrightness:(float)b forKeyboard:(unsigned long long)k;
- (BOOL)setBrightness:(float)b fadeSpeed:(int)ms commit:(BOOL)c forKeyboard:(unsigned long long)k;
- (BOOL)isBacklightSuppressedOnKeyboard:(unsigned long long)k;
- (BOOL)isBacklightDimmedOnKeyboard:(unsigned long long)k;
- (BOOL)suspendIdleDimming:(BOOL)s forKeyboard:(unsigned long long)k;
@end

// ponytail: calibration knobs.
static const float BRIGHT = 0.5f;   // at or above this your level is visible enough to flash from; below, "on" means 100%
static const int WAKE_MS = 400;     // how long an idle-dimmed light takes to come back
static const int MAX_AWAY_S = 3600; // --until-back gives up after an hour

static NSString *const BUILTINS =
  @"done    = off/120 on/120 x3\n"
  @"ask     = off/150 on/250 x2\n"
  @"error   = off/120 on/600 off/120 on/150 off/120 on/600\n"
  @"breathe = ~off/700 ~on/700 x2\n";

// Your level is written here for the length of a flash. If a flash is force-killed (or the Mac
// loses power) mid-flash, the next run finds it and puts your level back first.
static const char *RESTORE = "/tmp/kbflash.restore";

static KeyboardBrightnessClient *c;
static unsigned long long k;
#define HAS(sel) [c respondsToSelector:@selector(sel)]

static NSDictionary *patterns(void) {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  NSString *user = [NSString stringWithContentsOfFile:[@"~/.config/kbflash/patterns" stringByExpandingTildeInPath]
                                             encoding:NSUTF8StringEncoding error:nil];
  for (NSString *src in @[BUILTINS, user ?: @""])  // user file second, so it overrides built-ins
    for (NSString *line in [src componentsSeparatedByString:@"\n"]) {
      NSString *l = [[line componentsSeparatedByString:@"#"][0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      NSRange eq = [l rangeOfString:@"="];
      if (eq.location == NSNotFound) continue;
      NSString *name = [[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      NSString *steps = [[l substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (name.length && steps.length) d[name] = steps;
    }
  return d;
}

typedef struct { float level; int ms; BOOL fade; } Step;
enum { MAX_STEPS = 200 };

// Parse "off/120 on/120 x3" into steps. Returns the count, or -1 with a message on a bad token.
static int parse(NSString *text, float me, Step *out) {
  float hi = me >= BRIGHT ? me : 1.0f;
  int n = 0, group = 0;
  for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
    if (!raw.length) continue;
    const char *t = raw.UTF8String;
    if (t[0] == 'x') {
      int reps = atoi(t + 1), len = n - group;
      if (reps < 1 || reps > 50) { fprintf(stderr, "kbflash: bad repeat '%s'\n", t); return -1; }
      for (int r = 1; r < reps && n + len <= MAX_STEPS; r++, n += len) memcpy(out + n, out + group, len * sizeof(Step));
      group = n;
      continue;
    }
    if (n >= MAX_STEPS) break;
    Step s = { .fade = t[0] == '~', .ms = 150 };
    if (s.fade) t++;
    char lvl[16] = {0};
    sscanf(t, "%15[^/]/%d", lvl, &s.ms);
    if (!strcmp(lvl, "on")) s.level = hi;
    else if (!strcmp(lvl, "off")) s.level = 0;
    else if (!strcmp(lvl, "me")) s.level = me;
    else if (lvl[0] >= '0' && lvl[0] <= '9') s.level = fminf(fmaxf(atof(lvl) / 100.0f, 0), 1);
    else { fprintf(stderr, "kbflash: bad step '%s' (use on, off, me or 0-100, then /ms)\n", raw.UTF8String); return -1; }
    s.ms = s.ms < 20 ? 20 : s.ms > 5000 ? 5000 : s.ms;
    out[n++] = s;
  }
  return n;
}

static void set(float v, int fadeMs) {
  // commit:YES is the path the brightness slider uses. commit:NO is a temporary override that
  // locks out the slider, the brightness keys and auto-brightness, so never use it.
  if (HAS(setBrightness:fadeSpeed:commit:forKeyboard:)) [c setBrightness:v fadeSpeed:fadeMs commit:YES forKeyboard:k];
  else [c setBrightness:v forKeyboard:k];
}

// Is the built-in screen on? With it asleep (or the lid closed) macOS turns the keyboard off and
// reports its level as 0, so a flash can't show and would save 0 as your level.
static BOOL builtInScreenOn(void) {
  CGDirectDisplayID ids[16]; uint32_t n = 0;
  CGGetOnlineDisplayList(16, ids, &n);
  for (uint32_t i = 0; i < n; i++)
    if (CGDisplayIsBuiltin(ids[i])) return CGDisplayIsActive(ids[i]) && !CGDisplayIsAsleep(ids[i]);
  return NO;
}

// Play once (pattern already validated). 0 = played, 1 = skipped.
static int play(NSString *text) {
  if (!builtInScreenOn()) return 1;
  BOOL sup = HAS(isBacklightSuppressedOnKeyboard:) && [c isBacklightSuppressedOnKeyboard:k];
  BOOL dim = HAS(isBacklightDimmedOnKeyboard:) && [c isBacklightDimmedOnKeyboard:k];
  BOOL canWake = HAS(suspendIdleDimming:forKeyboard:);
  // Idle timeout sets both flags; a bright room sets only "suppressed". macOS ignores writes in a
  // bright room, and overriding it is what locks the slider, so leave it.
  if ((sup && !dim) || (dim && !canWake)) return 1;

  // Hold idle dimming off (macOS's own keep-awake switch) for the flash: an idle-dimmed light comes
  // back at your real level, and a lit one can't time out halfway through.
  if (canWake) [c suspendIdleDimming:YES forKeyboard:k];
  if (dim) usleep(WAKE_MS * 1000);

  float me = [c brightnessForKeyboard:k];
  // Woken from idle but still reading 0: macOS is keeping it off for some other reason, and 0 isn't
  // your level. Writing anything now would save it, so leave it.
  if (dim && me < 0.01f) { [c suspendIdleDimming:NO forKeyboard:k]; return 1; }
  FILE *f = fopen(RESTORE, "w");
  if (f) { fprintf(f, "%f\n", me); fclose(f); }
  Step steps[MAX_STEPS];
  int n = parse(text, me, steps);
  for (int i = 0; i < n && !stopping; i++) { set(steps[i].level, steps[i].fade ? steps[i].ms : 0); usleep(steps[i].ms * 1000); }
  set(me, 0);
  unlink(RESTORE);

  if (canWake) [c suspendIdleDimming:NO forKeyboard:k];
  return 0;
}

static double idleSeconds(void) { // time since the last keyboard/trackpad/mouse input
  io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"));
  CFNumberRef v = s ? IORegistryEntryCreateCFProperty(s, CFSTR("HIDIdleTime"), kCFAllocatorDefault, 0) : NULL;
  int64_t ns = 0;
  if (v) { CFNumberGetValue(v, kCFNumberSInt64Type, &ns); CFRelease(v); }
  if (s) IOObjectRelease(s);
  return ns / 1e9;
}

static int usage(void) {
  fprintf(stderr, "usage: kbflash [--until-back SECS] [pattern] [-- command args...]\n       kbflash --list\n");
  return 2;
}

int main(int argc, char **argv) { @autoreleasepool {
  NSString *name = nil;
  int every = 0, cmd = 0, status = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--")) { cmd = i + 1; break; }
    else if (!strcmp(argv[i], "--list") || !strcmp(argv[i], "-l")) {
      NSDictionary *d = patterns();
      for (NSString *p in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("%-10s %s\n", p.UTF8String, [d[p] UTF8String]);
      return 0;
    }
    else if (!strcmp(argv[i], "--until-back") || !strcmp(argv[i], "-u")) { if (++i >= argc) return usage(); every = atoi(argv[i]); }
    else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) return usage();
    else if (argv[i][0] == '{') continue; // agents like Codex append a JSON payload; ignore it
    else if (!name) name = @(argv[i]);
  }

  if (cmd) { // run the command first, flash after
    if (cmd >= argc) return usage();
    pid_t pid;
    if (posix_spawnp(&pid, argv[cmd], NULL, NULL, argv + cmd, environ) != 0) { perror(argv[cmd]); return 127; }
    int ws = 0;
    while (waitpid(pid, &ws, 0) < 0 && errno == EINTR) {}
    status = WIFEXITED(ws) ? WEXITSTATUS(ws) : 128 + WTERMSIG(ws);
    if (!name) name = status ? @"error" : @"done";
  }
  NSString *text = patterns()[name ?: @"done"] ?: ([name containsString:@"/"] ? name : nil);
  if (!text) { fprintf(stderr, "kbflash: no pattern '%s' (kbflash --list)\n", name.UTF8String); return cmd ? status : 2; }
  Step check[MAX_STEPS];
  if (parse(text, 1, check) < 0) return cmd ? status : 2; // reject a bad pattern before touching the light

  // One flasher at a time: a second would read the first one's mid-flash "off" as your level.
  int lock = open("/tmp/kbflash.lock", O_CREAT | O_RDWR, 0666);
  if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) return status;

  Class cls = NSClassFromString(@"KeyboardBrightnessClient");
  c = cls ? [cls new] : nil;
  NSArray *ids = [c copyKeyboardBacklightIDs];
  if (!ids.count) { fprintf(stderr, "kbflash: no keyboard backlight found\n"); return cmd ? status : 1; }
  k = [ids[0] unsignedLongLongValue];

  FILE *f = fopen(RESTORE, "r"); // a previous flash died mid-way: put its level back
  float was;
  if (f) {
    if (fscanf(f, "%f", &was) == 1 && was >= 0 && was <= 1) set(was, 0);
    if (HAS(suspendIdleDimming:forKeyboard:)) [c suspendIdleDimming:NO forKeyboard:k]; // it died holding this too
    fclose(f); unlink(RESTORE);
  }

  struct sigaction sa = { .sa_handler = onSignal }; // no SA_RESTART, so a signal wakes usleep/sleep early
  sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);

  NSDate *start = [NSDate date];
  play(text);
  // --until-back: keep flashing while nobody has touched the Mac since we started.
  while (every > 0 && !stopping) {
    sleep(every < 5 ? 5 : every);
    double away = -[start timeIntervalSinceNow];
    if (idleSeconds() < away || away > MAX_AWAY_S) break;
    if (!stopping) play(text);
  }
  return status;
}}
