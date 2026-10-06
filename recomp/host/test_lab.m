// The Test Lab window (DS_TEST_LAB=1): the Linux port's test panel, in AppKit, beside the game's window in the same
// process. Content comes from your own archives (host/test_lab/lab_content.py, through lab_tool.py); each request is a
// Skrit script (lab_commands.py) handed to the game through <lab data>/lab/request and answered in .../response by
// runtime/win32/test_lab.c on the game thread. Every request, reply and review is kept in .../history.jsonl.
#import <AppKit/AppKit.h>
#include <sys/stat.h>

static NSString *lab_data, *lab_game, *lab_tool;

@interface DSLab : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property NSWindow *win; @property NSDictionary *catalog; @property NSArray<NSDictionary *> *shown;
@property NSTextField *status, *countLabel, *note, *count, *interval; @property NSTextView *details, *log;
@property NSPopUpButton *group, *target, *castPath; @property NSSearchField *search; @property NSButton *bases, *primary, *equip, *immortal, *friendly, *sweepButton;
@property NSTableView *table; @property NSMutableArray<NSView *> *controls, *spawnOnly, *castOnly, *spellOnly;
@property NSMutableDictionary *pending; @property NSDictionary *last; @property NSMutableArray *sweep;
@property double nextStatus, nextSweep; @property uint64_t sequence; @property BOOL ready; @property NSString *statusCode;
@end

static double now(void) { return [NSDate date].timeIntervalSince1970; }
static NSString *labdir(void) { return [lab_data stringByAppendingPathComponent:@"lab"]; }

/* lab_tool.py: a JSON request in, its output back (nil if Python can't be run) */
static NSString *tool(NSArray *args, NSData *input, int *status)
{
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    t.arguments = [@[lab_tool] arrayByAddingObjectsFromArray:args];
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe]; t.standardInput = in; t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    if (input) [in.fileHandleForWriting writeData:input];
    [in.fileHandleForWriting closeFile];
    NSData *d = [out.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    if (status) *status = t.terminationStatus;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

@implementation DSLab
- (NSButton *)button:(NSString *)title action:(SEL)a in:(NSStackView *)row control:(BOOL)c
{
    NSButton *b = [NSButton buttonWithTitle:title target:self action:a]; b.controlSize = NSControlSizeSmall; b.font = [NSFont systemFontOfSize:11];
    [row addArrangedSubview:b]; if (c) [self.controls addObject:b]; return b;
}
- (NSStackView *)row:(NSStackView *)col { NSStackView *r = [NSStackView new]; r.orientation = NSUserInterfaceLayoutOrientationHorizontal; r.spacing = 6; [col addArrangedSubview:r]; return r; }
- (NSTextField *)label:(NSString *)s in:(NSStackView *)row { NSTextField *l = [NSTextField wrappingLabelWithString:s]; l.font = [NSFont systemFontOfSize:11]; [row addArrangedSubview:l]; return l; }
- (NSTextView *)textIn:(NSStackView *)col height:(CGFloat)h
{
    NSScrollView *sv = [NSTextView scrollableTextView]; NSTextView *tv = sv.documentView; tv.editable = NO; tv.font = [NSFont systemFontOfSize:11];
    [sv.heightAnchor constraintEqualToConstant:h].active = YES; [col addArrangedSubview:sv]; return tv;
}
- (void)build
{
    NSRect v = NSScreen.mainScreen.visibleFrame;
    self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(NSMaxX(v) - 550, v.origin.y + 10, 540, v.size.height - 20)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.win.releasedWhenClosed = NO; self.win.title = @"Test Lab"; self.win.delegate = self;
    self.controls = [NSMutableArray array]; self.spawnOnly = [NSMutableArray array]; self.castOnly = [NSMutableArray array]; self.spellOnly = [NSMutableArray array];
    NSStackView *col = [NSStackView new]; col.orientation = NSUserInterfaceLayoutOrientationVertical; col.alignment = NSLayoutAttributeLeading; col.spacing = 6;
    col.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10); col.translatesAutoresizingMaskIntoConstraints = NO;
    self.win.contentView = [NSView new]; [self.win.contentView addSubview:col];
    [NSLayoutConstraint activateConstraints:@[[col.leadingAnchor constraintEqualToAnchor:self.win.contentView.leadingAnchor], [col.trailingAnchor constraintEqualToAnchor:self.win.contentView.trailingAnchor],
                                              [col.topAnchor constraintEqualToAnchor:self.win.contentView.topAnchor], [col.bottomAnchor constraintEqualToAnchor:self.win.contentView.bottomAnchor]]];
    NSStackView *r = [self row:col];
    [self label:@"Load a single-player save in the game, then prepare your hero. Click the game to play; F12 gives the mouse back. "
                 "These saves are copies: your own are never changed." in:r].preferredMaxLayoutWidth = 500;
    r = [self row:col]; [self button:@"Open test folder" action:@selector(openFolder) in:r control:NO]; [self button:@"Export report…" action:@selector(exportReport) in:r control:NO];
    r = [self row:col]; self.status = [self label:@"Reading the installed content…" in:r]; self.status.font = [NSFont boldSystemFontOfSize:11];
    r = [self row:col];
    [self button:@"Prepare hero / unlock skills" action:@selector(prepare) in:r control:YES];
    [self button:@"Invincible" action:@selector(invincible) in:r control:YES]; [self button:@"Vulnerable" action:@selector(vulnerable) in:r control:YES];
    r = [self row:col];
    [self button:@"Refill life / mana / power" action:@selector(refill) in:r control:YES]; [self button:@"Wound hero" action:@selector(wound) in:r control:YES];
    [self button:@"Clean up test objects" action:@selector(cleanup) in:r control:YES];
    r = [self row:col];
    self.group = [NSPopUpButton new]; self.group.controlSize = NSControlSizeSmall; self.group.font = [NSFont systemFontOfSize:11];
    for (NSArray *g in @[@[@"locations", @"Locations"], @[@"gear", @"Gear"], @[@"enemies", @"Enemies"], @[@"spells", @"Spells / power templates"], @[@"powers", @"Active powers"],
                         @[@"objects", @"Other objects"], @[@"effects", @"Effect definitions"], @[@"shaders", @"Shader definitions"]]) {
        [self.group addItemWithTitle:g[1]]; self.group.lastItem.representedObject = g[0];
    }
    self.group.target = self; self.group.action = @selector(populate); [r addArrangedSubview:self.group];
    self.bases = [NSButton checkboxWithTitle:@"Include bases / developer content" target:self action:@selector(populate)]; self.bases.controlSize = NSControlSizeSmall; self.bases.font = [NSFont systemFontOfSize:11]; [r addArrangedSubview:self.bases];
    self.search = [NSSearchField new]; self.search.placeholderString = @"Search name, template, damage type, target or effect…"; self.search.target = self; self.search.action = @selector(populate);
    self.search.controlSize = NSControlSizeSmall; [col addArrangedSubview:self.search]; [self.search.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-20].active = YES;
    self.table = [NSTableView new]; NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:@"e"]; tc.title = @"Content"; [self.table addTableColumn:tc];
    self.table.headerView = nil; self.table.dataSource = self; self.table.delegate = self; self.table.rowHeight = 16; self.table.target = self; self.table.doubleAction = @selector(runSelected);
    NSScrollView *ts = [NSScrollView new]; ts.documentView = self.table; ts.hasVerticalScroller = YES; ts.borderType = NSBezelBorder;
    [col addArrangedSubview:ts]; [ts.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-20].active = YES;
    [ts.heightAnchor constraintGreaterThanOrEqualToConstant:150].active = YES; [ts setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    self.details = [self textIn:col height:110]; [self.details.enclosingScrollView.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-20].active = YES;
    r = [self row:col]; self.countLabel = [self label:@"" in:r];
    r = [self row:col];
    self.primary = [self button:@"Travel" action:@selector(runSelected) in:r control:YES];
    self.equip = [self button:@"Give and equip" action:@selector(giveEquip) in:r control:YES];
    NSTextField *cl = [self label:@"Count:" in:r]; [self.spawnOnly addObject:cl];
    self.count = [NSTextField textFieldWithString:@"1"]; self.count.controlSize = NSControlSizeSmall; [self.count.widthAnchor constraintEqualToConstant:34].active = YES; [r addArrangedSubview:self.count]; [self.spawnOnly addObject:self.count];
    self.immortal = [NSButton checkboxWithTitle:@"Invincible spawn" target:nil action:nil]; self.immortal.state = NSControlStateValueOn;
    self.friendly = [NSButton checkboxWithTitle:@"Friendly spawn" target:nil action:nil];
    for (NSButton *b in @[self.immortal, self.friendly]) { b.controlSize = NSControlSizeSmall; b.font = [NSFont systemFontOfSize:11]; [r addArrangedSubview:b]; [self.spawnOnly addObject:b]; }
    r = [self row:col];
    NSTextField *ca = [self label:@"Cast at:" in:r]; [self.castOnly addObject:ca];
    self.target = [NSPopUpButton new]; self.target.controlSize = NSControlSizeSmall; self.target.font = [NSFont systemFontOfSize:11];
    for (NSArray *t in @[@[@"auto", @"Automatic"], @[@"self", @"Self"], @[@"target", @"Test target"], @[@"ground", @"Ground near target"]]) { [self.target addItemWithTitle:t[1]]; self.target.lastItem.representedObject = t[0]; }
    [r addArrangedSubview:self.target]; [self.castOnly addObject:self.target];
    [self button:@"Target party member…" action:@selector(partyTarget) in:r control:YES]; [self button:@"Kill test target" action:@selector(corpse) in:r control:YES];
    r = [self row:col];
    NSTextField *sp = [self label:@"Spell path:" in:r]; [self.spellOnly addObject:sp];
    self.castPath = [NSPopUpButton new]; self.castPath.controlSize = NSControlSizeSmall; self.castPath.font = [NSFont systemFontOfSize:11];
    [self.castPath addItemWithTitle:@"Trigger effect"]; [self.castPath addItemWithTitle:@"Animated cast job"]; [r addArrangedSubview:self.castPath]; [self.spellOnly addObject:self.castPath];
    self.sweepButton = [self button:@"Cast filtered spells in sequence" action:@selector(startSweep) in:r control:YES]; [self.spellOnly addObject:self.sweepButton];
    NSButton *stop = [self button:@"Stop" action:@selector(stopSweep) in:r control:NO]; [self.spellOnly addObject:stop];
    NSTextField *il = [self label:@"Seconds:" in:r]; [self.spellOnly addObject:il];
    self.interval = [NSTextField textFieldWithString:@"6"]; self.interval.controlSize = NSControlSizeSmall; [self.interval.widthAnchor constraintEqualToConstant:30].active = YES; [r addArrangedSubview:self.interval]; [self.spellOnly addObject:self.interval];
    self.log = [self textIn:col height:120]; [self.log.enclosingScrollView.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-20].active = YES;
    self.note = [NSTextField textFieldWithString:@""]; self.note.placeholderString = @"Visual result / artefact / missing effect…"; self.note.controlSize = NSControlSizeSmall;
    [col addArrangedSubview:self.note]; [self.note.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-20].active = YES;
    r = [self row:col]; [self button:@"Mark last test: looks correct" action:@selector(markPass) in:r control:NO]; [self button:@"Mark last test: problem" action:@selector(markFail) in:r control:NO];
    NSTextField *hint = [self label:@"A queued action is not a rendering pass: check it in the game before marking the result. The game's shader effects "
                         "(Options > Video > Shaders) run as Metal shaders here; the effect and shader lists are an inventory of your files." in:[self row:col]];
    hint.textColor = NSColor.secondaryLabelColor; hint.preferredMaxLayoutWidth = 500;
    [self populate];
    [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self.win orderFront:nil];
    [self append:@"Reading your game's content…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = tool(@[@"catalog", lab_game], nil, NULL);
        NSDictionary *c = out ? [NSJSONSerialization JSONObjectWithData:[out dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![c isKindOfClass:NSDictionary.class]) { [self append:@"The content scan failed (it needs /usr/bin/python3, from the Xcode command line tools)."]; return; }
            self.catalog = c;
            [[NSJSONSerialization dataWithJSONObject:c options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[lab_data stringByAppendingPathComponent:@"catalog.json"] atomically:YES];
            NSArray *errs = c[@"errors"]; [self append:[@"Content catalog ready. " stringByAppendingString:[[errs subarrayWithRange:NSMakeRange(0, MIN(5, errs.count))] componentsJoinedByString:@"; "]]];
            [self populate];
        });
    });
}
- (void)append:(NSString *)s { [self.log.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:[s stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.labelColor}]]; [self.log scrollToEndOfDocument:nil]; }
- (NSString *)groupKey { return self.group.selectedItem.representedObject; }
- (void)populate
{
    NSString *g = self.groupKey;
    NSDictionary *actions = @{@"locations": @"Travel", @"gear": @"Give item", @"enemies": @"Spawn enemy", @"spells": @"Cast spell / template", @"powers": @"Trigger active power", @"objects": @"Spawn object"};
    self.primary.title = actions[g] ?: @"Definitions only"; self.primary.hidden = !actions[g]; self.equip.hidden = ![g isEqualToString:@"gear"];
    for (NSView *v in self.spawnOnly) v.hidden = !([g isEqualToString:@"enemies"] || [g isEqualToString:@"objects"]);
    for (NSView *v in self.castOnly) v.hidden = !([g isEqualToString:@"spells"] || [g isEqualToString:@"powers"]);
    for (NSView *v in self.spellOnly) v.hidden = ![g isEqualToString:@"spells"];
    NSMutableArray *shown = [NSMutableArray array]; NSArray *all = self.catalog[g] ?: @[];
    NSArray *words = [self.search.stringValue.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (NSDictionary *e in all) {
        NSString *src = e[@"source"] ?: @""; BOOL dev = [src containsString:@"/dev/"] || [src containsString:@"/test/"];
        if (self.bases.state != NSControlStateValueOn && ([e[@"base"] boolValue] || dev)) continue;
        NSString *hay = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:e options:0 error:nil] encoding:NSUTF8StringEncoding].lowercaseString;
        BOOL ok = YES; for (NSString *w in words) if (w.length && ![hay containsString:w]) { ok = NO; break; }
        if (ok) [shown addObject:e];
    }
    [shown sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [[a[@"label"] lowercaseString] compare:[b[@"label"] lowercaseString]]; return r != NSOrderedSame ? r : [a[@"id"] compare:b[@"id"]]; }];
    self.shown = shown; [self.table reloadData];
    self.countLabel.stringValue = [NSString stringWithFormat:@"%lu shown / %lu definitions in your game files", (unsigned long)shown.count, (unsigned long)all.count];
    if (shown.count) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self describe];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)self.shown.count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row
{
    NSTextField *f = [t makeViewWithIdentifier:@"cell" owner:self];
    if (!f) { f = [NSTextField labelWithString:@""]; f.identifier = @"cell"; f.font = [NSFont systemFontOfSize:11]; f.lineBreakMode = NSLineBreakByTruncatingTail; }
    NSDictionary *e = self.shown[row];
    f.stringValue = [e[@"label"] isEqualToString:e[@"id"]] ? e[@"label"] : [NSString stringWithFormat:@"%@  [%@]", e[@"label"], e[@"id"]];
    return f;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n { [self describe]; }
- (NSDictionary *)selected { NSInteger r = self.table.selectedRow; return r >= 0 && r < (NSInteger)self.shown.count ? self.shown[r] : nil; }
- (void)describe
{
    NSMutableArray *lines = [NSMutableArray array];
    [self.selected enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        NSString *s = [v isKindOfClass:NSArray.class] ? [v componentsJoinedByString:@", "] : [v description];
        if (s.length && ![s isEqualToString:@"0"]) [lines addObject:[NSString stringWithFormat:@"%@: %@", k, s]];
    }];
    self.details.string = [lines componentsJoinedByString:@"\n\n"];
}

// ---- the mailbox (as the Linux panel's Bridge: one request at a time, never retried, all recorded)
- (void)record:(NSDictionary *)r
{
    NSString *h = [labdir() stringByAppendingPathComponent:@"history.jsonl"];
    NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:r options:0 error:nil] mutableCopy]; [d appendBytes:"\n" length:1];
    NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:h];
    if (!f) { [d writeToFile:h atomically:NO]; return; }
    [f seekToEndOfFile]; [f writeData:d]; [f closeFile];
}
- (void)submit:(NSString *)action entry:(NSDictionary *)entry options:(NSDictionary *)options
{
    if (self.pending) return;
    int st = 0;
    NSData *req = [NSJSONSerialization dataWithJSONObject:@{@"action": action, @"entry": entry ?: @{}, @"options": options ?: @{}} options:0 error:nil];
    NSString *code = tool(@[@"skrit"], req, &st);
    if (!code || st) { [self append:code.length ? code : @"The lab's helper could not be run (/usr/bin/python3)."]; [self stopSweep]; return; }
    if ([code lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 16000) { [self append:@"Test command is too long"]; return; }
    self.sequence++;
    NSMutableDictionary *r = [@{@"id": @(self.sequence), @"time": @(now()), @"action": action, @"content": entry[@"id"] ?: @"", @"options": options ?: @{},
                               @"status": @"submitted", @"backend": @"macos-metal"} mutableCopy];
    if (![action isEqualToString:@"status"]) [self record:r];
    NSString *tmp = [labdir() stringByAppendingPathComponent:@"request.tmp"];
    [[NSString stringWithFormat:@"%llu exec\n%@", self.sequence, code] writeToFile:tmp atomically:NO encoding:NSASCIIStringEncoding error:nil];
    chmod(tmp.fileSystemRepresentation, 0600);
    rename(tmp.fileSystemRepresentation, [labdir() stringByAppendingPathComponent:@"request"].fileSystemRepresentation);
    self.pending = r;
}
- (NSDictionary *)poll
{
    if (!self.pending) return nil;
    NSString *resp = [NSString stringWithContentsOfFile:[labdir() stringByAppendingPathComponent:@"response"] encoding:NSUTF8StringEncoding error:nil];
    NSArray *p = [[resp stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\t"];
    if (p.count >= 3 && [p[0] isEqualToString:[self.pending[@"id"] description]]) {
        NSString *msg = [[p subarrayWithRange:NSMakeRange(2, p.count - 2)] componentsJoinedByString:@"\t"];
        NSMutableDictionary *r = [self.pending mutableCopy]; r[@"status"] = [msg hasPrefix:@"ERROR:"] ? @"error" : p[1]; r[@"message"] = msg; r[@"finished"] = @(now());
        self.pending = nil; if (![r[@"action"] isEqualToString:@"status"]) [self record:r];
        return r;
    }
    if (now() - [self.pending[@"time"] doubleValue] < 120) return nil;
    NSMutableDictionary *r = [self.pending mutableCopy]; r[@"status"] = @"unconfirmed";
    r[@"message"] = @"No reply after 120 seconds. Check the game and log; this command was not retried.";
    self.pending = nil; unlink([labdir() stringByAppendingPathComponent:@"request"].fileSystemRepresentation);
    if (![r[@"action"] isEqualToString:@"status"]) [self record:r];
    return r;
}
- (void)tick
{
    NSDictionary *r = [self poll];
    if (r) {
        if ([r[@"action"] isEqualToString:@"status"]) { self.ready = [r[@"status"] isEqualToString:@"ok"] && [r[@"message"] hasPrefix:@"Ready"]; self.status.stringValue = r[@"message"]; }
        else {
            self.last = r; [self append:[NSString stringWithFormat:@"%@ %@: %@", r[@"action"], r[@"content"], r[@"message"]]];
            self.nextSweep = [NSDate timeIntervalSinceReferenceDate] + MAX(3, self.interval.integerValue);
            if (![r[@"status"] isEqualToString:@"ok"]) [self stopSweep];
        }
    }
    double t = [NSDate timeIntervalSinceReferenceDate];
    if (!self.pending) {
        if (t >= self.nextStatus) { [self submit:@"status" entry:nil options:nil]; self.nextStatus = t + 3; }
        else if (self.sweep.count && self.ready && t >= self.nextSweep) {
            NSDictionary *e = self.sweep.firstObject; [self.sweep removeObjectAtIndex:0];
            [self submit:@"cast" entry:e options:@{@"target": self.target.selectedItem.representedObject, @"direct": @(self.castPath.indexOfSelectedItem == 0)}];
        }
    }
    BOOL on = self.ready && self.catalog && !self.pending && !self.sweep.count;
    for (NSButton *b in self.controls) b.enabled = on;
}

// ---- actions
- (void)prepare { [self submit:@"prepare" entry:nil options:@{@"skills": self.catalog[@"skills"] ?: @[]}]; }
- (void)invincible { [self submit:@"invincible" entry:nil options:@{@"enabled": @YES}]; }
- (void)vulnerable { [self submit:@"invincible" entry:nil options:@{@"enabled": @NO}]; }
- (void)refill { [self submit:@"refill" entry:nil options:nil]; }
- (void)wound { [self submit:@"wound" entry:nil options:nil]; }
- (void)cleanup { [self submit:@"cleanup" entry:nil options:nil]; }
- (void)corpse { [self submit:@"corpse" entry:nil options:nil]; }
- (NSDictionary *)options
{
    return @{@"count": @(MAX(1, MIN(16, self.count.integerValue))), @"immortal": @(self.immortal.state == NSControlStateValueOn), @"friendly": @(self.friendly.state == NSControlStateValueOn),
             @"target": self.target.selectedItem.representedObject, @"direct": @(self.castPath.indexOfSelectedItem == 0)};
}
- (void)runSelected
{
    NSDictionary *e = self.selected; if (!e || !self.ready || self.pending) return;
    NSString *a = @{@"locations": @"travel", @"gear": @"give", @"enemies": @"spawn", @"spells": @"cast", @"powers": @"power", @"objects": @"spawn"}[self.groupKey];
    if (a) [self submit:a entry:e options:self.options];
}
- (void)giveEquip { NSDictionary *e = self.selected; if (e) [self submit:@"equip" entry:e options:self.options]; }
- (void)partyTarget
{
    NSAlert *a = [NSAlert new]; a.messageText = @"Party target"; a.informativeText = @"Party member number (1 is usually the hero). Use a companion for resurrection tests.";
    NSTextField *f = [NSTextField textFieldWithString:@"2"]; f.frame = NSMakeRect(0, 0, 60, 22); a.accessoryView = f;
    [a addButtonWithTitle:@"Target"]; [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [self.target selectItemAtIndex:2];
    [self submit:@"party_target" entry:nil options:@{@"member": @(MAX(1, MIN(6, f.integerValue)))}];
}
- (void)startSweep
{
    if (![self.groupKey isEqualToString:@"spells"]) return;
    self.sweep = [NSMutableArray array]; for (NSDictionary *e in self.shown) if (![e[@"base"] boolValue]) [self.sweep addObject:e];
    self.nextSweep = [NSDate timeIntervalSinceReferenceDate];
    [self append:[NSString stringWithFormat:@"Sequence: %lu spell templates. Pauses on a rejected request; Stop leaves current effects running.", (unsigned long)self.sweep.count]];
}
- (void)stopSweep { if (self.sweep.count) [self append:[NSString stringWithFormat:@"Sequence stopped with %lu casts remaining.", (unsigned long)self.sweep.count]]; self.sweep = nil; }
- (void)mark:(NSString *)status
{
    if (!self.last) { [self append:@"Run a test first."]; return; }
    NSMutableDictionary *r = [self.last mutableCopy]; r[@"status"] = status; r[@"note"] = self.note.stringValue; r[@"reviewed"] = @(now());
    [self record:r]; [self append:[NSString stringWithFormat:@"%@: %@ %@", status, r[@"content"], r[@"note"]]]; self.note.stringValue = @"";
}
- (void)markPass { [self mark:@"visual-pass"]; }
- (void)markFail { [self mark:@"visual-fail"]; }
- (void)openFolder { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:lab_data]]; }
- (void)exportReport
{
    NSSavePanel *p = [NSSavePanel savePanel]; p.nameFieldStringValue = @"test-report.json"; p.directoryURL = [NSURL fileURLWithPath:lab_data];
    if ([p runModal] != NSModalResponseOK) return;
    NSMutableArray *records = [NSMutableArray array];
    for (NSString *line in [[NSString stringWithContentsOfFile:[labdir() stringByAppendingPathComponent:@"history.jsonl"] encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"])
        if (line.length) { id o = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; if (o) [records addObject:o]; }
    NSDictionary *rep = @{@"backend": @"macos-metal", @"shader_execution_verified": @NO, @"catalog": self.catalog ?: [NSNull null], @"history": records,
                          @"note": @"Submitted/ok records describe command handling. Only visual-pass/visual-fail are manual rendering reviews. "
                                   "The game's shader effects run as Metal shaders when Options > Video > Shaders is on; check effects in both settings."};
    if ([[NSJSONSerialization dataWithJSONObject:rep options:NSJSONWritingPrettyPrinted error:nil] writeToURL:p.URL atomically:YES]) [self append:[@"Exported " stringByAppendingString:p.URL.path]];
}
@end

static DSLab *lab;
void lab_window_setup(const char *data, const char *game, const char *tooldir)
{
    lab_data = @(data); lab_game = @(game); lab_tool = [@(tooldir) stringByAppendingPathComponent:@"lab_tool.py"];
    mkdir(labdir().fileSystemRepresentation, 0700);
    unlink([labdir() stringByAppendingPathComponent:@"request"].fileSystemRepresentation);
    unlink([labdir() stringByAppendingPathComponent:@"response"].fileSystemRepresentation);
}
void lab_window_show(void)   /* main thread, when the game's window first appears */
{
    if (lab || !lab_data) return;
    lab = [DSLab new]; lab.sequence = (uint64_t)(now() * 1000) % 2000000000ull;
    [lab record:@{@"action": @"session", @"time": @(now()), @"game": lab_game, @"backend": @"macos-metal",
                  @"settings": @{@"resolution": @(getenv("DS_RESOLUTION") ?: ""), @"viewDistance": @(getenv("DS_DRAW_DISTANCE") ?: ""), @"frameRate": @(getenv("DSR_FPSCAP") ?: "")},
                  @"frame_trace": @(getenv("DS_FRAME_TRACE") ?: "")}];
    [lab build];
}
