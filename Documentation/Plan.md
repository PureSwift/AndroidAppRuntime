# Android host — Plan

**Status:** phases 0 to 4 (§11) are done, but for running the x86_64 and
armeabi-v7a ABIs on hardware. Surfaces (§6.3), web views (§6.4), files
(§6.5), defaults (§6.6), the model store (§6.7), documents (§6.8),
notifications (§6.9), media players (§6.10), the clipboard (§6.11),
secrets and sign-in (§6.12), now playing (§6.13), contacts (§6.14) and
calendars (§6.15) came after them.

**Calendars:** AppRuntime's Calendars contract. A guest reads the user's
calendars, lists what happens in a range as Android expands it, and adds,
changes and removes events, one occurrence of a series or the rest of it.

- **How:** `AndroidHostCalendars` gives AppRuntime's `HostCalendars` an
  `AndroidCalendarStore` over `CalendarContract`: a range is `Instances`,
  one occurrence an exception, and the rest of a series an `UNTIL` and a
  new event. Access is Android's `READ_CALENDAR` and `WRITE_CALENDAR`,
  and a `ContentObserver` says when the store changed (§6.15).
- **ExampleCalendar runs:** `Scripts/example-calendar.sh` packages
  AppRuntime's `ExampleCalendar` with a manifest of its own, and drives it
  and Android's permission dialog on the emulator, which is in New York,
  reading the calendar provider with `adb shell content`.
  - Allow asks with Android's dialog; a holiday on a read-only calendar
    the check put there is on its day, all day.
  - Add Standup saves a weekly series in the default calendar, with its
    rule, length, place and alarm as Android keeps them, and the
    provider's expansion gives its four Tuesdays.
  - Add Day Off saves an all-day event at UTC midnight.
  - Move Second makes an exception for the second Tuesday, and the
    series' other occurrences stay. That needed the series to have a
    sync identifier, which the host gives it on a calendar with no sync
    adapter.
  - Cancel From Third ends the series' rule before the third Tuesday.
  - An event another app adds is listed, as the store says it changed,
    and December and November again read as they should.

  All 26 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 10 Swift tests cover an event's and a calendar's
  fields as they cross, the default calendar, a range, adding and
  changing, one occurrence, this and the ones after, removing, Android's
  errors, a write-only app through `HostCalendars`, and access from
  Android's permissions, against a scripted provider. The packager's
  tests cover the permissions.

**Contacts:** AppRuntime's Contacts contract. A guest reads the user's
address book, as Android's Contacts app shows it, finds people by name,
and adds, changes and removes them.

- **How:** `AndroidHostContacts` gives AppRuntime's `HostContacts` an
  `AndroidContactDirectory` over `ContactsContract`: a person is the
  unified contact, with the data rows of each raw contact. Access is
  Android's `READ_CONTACTS` and `WRITE_CONTACTS`, and a `ContentObserver`
  says when the store changed (§6.14).
- **ExampleContacts runs:** `Scripts/example-contacts.sh` packages
  AppRuntime's `ExampleContacts`, with a manifest that reads and writes
  contacts, and drives it and Android's permission dialog on the
  emulator, reading the contacts provider with `adb shell content`.
  - Allow asks with Android's dialog; the app lists a person the check put
    there, with their phone's label.
  - Add Ada saves a mobile phone, a work email, a home address with its
    country's code, and a birthday, each as Android keeps it.
  - Promote Ada adds a job and a second email, keeping the rows she had.
  - A search is Android's own, by the start of a name.
  - A person another app adds is listed, as the store says it changed.
  - Remove Ada removes her from the device.

  All 22 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 5 Swift tests cover a person's fields as they cross,
  saving, finding and removing, Android's errors, access from Android's
  permissions, and an app that only reads, against a scripted provider.
  The packager's tests cover the permissions.

**Now playing:** AppRuntime's NowPlaying additions to the media player. A
guest says what it plays, and Android shows it with its buttons in the
notification shade, on the lock screen and to headphones; with
`.audio(background: true)` it plays on in the background.

- **How:** `AndroidHostMedia` gives `HostMediaPlayback`'s
  `showNowPlaying` one Media3 `MediaSession`, over a stand-in player that
  shows what Swift says and hands its buttons back to
  `HostMediaPlayback.remote`. The session lives in a `MediaSessionService`,
  in the foreground while it plays where the manifest allows (§6.13).
- **ExampleMedia plays on:** `Scripts/example-nowplaying.sh` packages
  AppRuntime's `ExampleMedia` with a manifest of its own that plays in the
  background, and drives it, its session and its notification on the
  emulator with the media keys and `dumpsys`.
  - The session shows the song, its artist and its album; the
    notification its title, artist and cover.
  - Playing puts the service in the foreground, as `mediaPlayback`.
  - The media keys pause, as the user, play, go to the app's next and
    previous songs, and skip back.
  - In the background the song plays on, Next changes songs, and the app
    plays the next one when a song ends.
  - Paused, the service leaves the foreground; back in front the app is as
    the keys left it.

  All 19 checks pass both from the native slice and from `App.wasm`
  through wasm2c. `Scripts/example-media.sh`, without the background,
  passes as before: leaving the front pauses.
- **Unit tests:** 3 Swift tests cover what the session is told, its
  artwork read once, the buttons the host and the guest answer, and
  playing on with the manifest's leave, against a scripted session. The
  packager's tests cover the service's type and permissions.

**Clipboard:** AppRuntime's Clipboard contract. A guest copies and pastes
text, links and images from code, knows what there is to paste without
reading it, and lets the user select a `Text` with `textSelection`.

- **How:** `AndroidHostClipboard` gives AppRuntime's `HostClipboard`
  Android's `ClipboardManager`. A link is the clip's URI with its text, an
  image a file the app shares through a `FileProvider`. `textSelection` is
  Compose's `SelectionContainer` (§6.11).
- **ExampleClipboard runs:** `Scripts/example-clipboard.sh` makes a logo,
  packages AppRuntime's `ExampleClipboard`, and drives it on the emulator,
  in landscape so its row of buttons fits.
  - Text, a link with its title, and a sensitive code are copied, and
    pasted back through Android's clipboard.
  - The logo is copied from the APK's assets as an image, and pasted as
    PNG.
  - What there is to paste is known without reading it, and Clear empties
    the clipboard.
  - A long press selects the result's text, and the platform copies it.

  All 25 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 4 Swift tests cover text and links, images, a refused
  read, and image files from the bundle and the app's own directories,
  against a scripted clipboard. The IR adapter's tests cover
  `textSelection`.
- **AppRuntime:** `HostFiles.wholeFiles`, which this host sets so that
  the clipboard's images and an editor's text reach the bundle and picked
  documents, came from this work.

**Secrets and sign-in:** AppRuntime's Secrets and WebAuthentication
contracts. A guest keeps small values, a token or a password, encrypted on
the device, and signs in through the provider's page in the system's
browser.

- **How:** `AndroidHostSecrets` gives AppRuntime's `HostSecrets` an
  AES-GCM key in the Android Keystore, and each secret encrypted with it in
  a file of `noBackupFilesDir`. `AndroidHostAuthentication` gives
  `HostWebAuthentication` a Custom Tab for the page, and an activity the
  packager declares for each of the app's schemes to catch the redirect
  (§6.12).
- **ExampleSignIn runs:** `Scripts/example-signin.sh` packages AppRuntime's
  `ExampleSignIn`, with a manifest that asks for `secrets` and declares its
  scheme, and drives it, Chrome's Custom Tab and the provider's redirect on
  the emulator. Its provider doesn't exist, so the check plays it: it reads
  the page's `state` from the tab's intent, and sends the redirect as the
  browser would.
  - The first read of the Keychain finds no token, without an error.
  - Sign In shows the page in a Custom Tab, and Back from it cancels the
    sign-in.
  - The redirect reaches the app, which keeps its token: one file in
    `no_backup`, named by a hash, with neither the token nor its key in it.
  - After a restart the token is there, and Sign Out removes it.
  - A private sign-in shows its page too.

  All 14 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 6 Swift tests cover keeping, finding, listing and
  removing secrets, a Keystore that can't be read, and the sign-in's
  redirect, Back, the guest's cancel and a page that can't be shown,
  against a scripted Keystore and browser. The packager's tests cover the
  redirect activity.

**Media players:** AppRuntime's MediaPlayer contract. A guest plays songs
and videos from its bundle, its files, a picked document or the network,
follows where playback is, and shows a player's picture with
`VideoPlayer`.

- **How:** `AndroidHostMedia` gives AppRuntime's `HostMediaPlayback` a
  Media3 `ExoPlayer` per player, which takes audio focus as media does and
  pauses when headphones are unplugged. A `VideoPlayer` node is the
  player's `PlayerView`. A file of the bundle is an `asset:///` URI, and a
  picked document its content URI (§6.10).
- **ExampleMedia runs:** `Scripts/example-media.sh` makes three
  eight-second songs, packages AppRuntime's `ExampleMedia` with a manifest
  that asks for `audio` and `network`, and drives it on the emulator,
  checking Android's audio service with `dumpsys audio`.
  - The first song loads from the APK's assets, plays and pauses, and
    Android hears its player start.
  - Next and Previous change songs, and a song that ends starts the next.
  - Leaving the front pauses it, and the app says why.
  - The video player is a `PlayerView`.

  All 18 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 7 Swift tests cover making and releasing players,
  finding the bundle's files and a picked document's, what Android
  reports, seeks answered once, settings, and the background, against
  scripted players. The IR adapter's tests cover the `VideoPlayer` node.
- **AppRuntime:** `HostMediaPlayback.findFile`, which this host sets, came
  from this work.

**Notifications:** AppRuntime's Notifications contract. A guest asks the
user's leave, shows a notification now or schedules one, gives it buttons,
and hears what the user did, with the app open or closed.

- **How:** `AndroidHostNotifications` gives AppRuntime's
  `HostNotifications` a presenter over `NotificationManager` and
  `AlarmManager`. Each category is a channel. A scheduled notification is
  kept on disk and posted when its alarm starts the app's process, with no
  guest; a tap or a button opens the app with it (§6.9). Push is
  `unsupported`: there's no Firebase Cloud Messaging yet.
- **ExampleNotifications runs:** `Scripts/example-notifications.sh`
  packages AppRuntime's `ExampleNotifications`, kitchen timers, with a
  manifest that asks for `notifications`, and drives it and the
  notification shade on the emulator, reading what's posted and the
  alarms with `dumpsys`.
  - Allow shows Android's prompt, and the answer is the app's.
  - A notification shown now is in the default channel; the app hears of
    it, and a tap in the shade opens the app with it.
  - A timer sets an alarm, and Cancel takes it away.
  - With the app's process killed, a timer's alarm starts it and posts
    the notification with its buttons; Stop opens the app, which stops
    the timer.
  - Registering for push is `unsupported`.

  All 29 checks pass both from the native slice and from `App.wasm`
  through wasm2c. The check waits for a real alarm, so it takes up to
  ten minutes.
- **Unit tests:** 15 Swift tests cover permission, exact timing, channels,
  posting, the foreground presentation, scheduling, replacing, limits,
  alarms and repeats, calendar triggers in the device's time zone,
  restarts, and responses that wait for the guest, against a scripted
  platform. The packager's tests cover the manifest's receiver and
  permissions.

**Documents:** AppRuntime's Documents contract. A guest asks the user for
files, a folder, or a place to save, keeps access to them, and is opened
with files from other apps. What the user picks is a directory `Files`
reaches.

- **How:** `AndroidHostDocuments` shows the Storage Access Framework's
  pickers from the Activity. What's picked becomes a grant that
  `AndroidHostFiles` reads and writes by content URI, walking a folder's
  paths by display name. A bookmark is a persisted URI permission. A
  photo comes from Android's own photo picker, read-only and never
  bookmarked (§6.8).
- **ExampleDocuments runs:** `Scripts/example-documents.sh` packages
  AppRuntime's `ExampleDocuments`, with a manifest that asks for
  `userFiles` and opens text, and drives it and Android's own pickers on
  the emulator, checking the user's files with `adb shell`.
  - A file is picked, changed and saved back.
  - A copy is saved where the save picker says, and later saves go to the
    copy.
  - A folder is picked and listed, and a file in it is read.
  - A photo is picked with Android's photo picker, with no media
    permission, and read; Back from the picker picks nothing.
  - A cancelled picker changes nothing.
  - Another app's `ACTION_EDIT` opens a file while the app runs, and
    `ACTION_VIEW` opens one read-only as it starts.

  All 46 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 28 Swift tests cover a document's paths, reads, writes,
  folders, access, release, sizes, and moves and copies across documents
  and the app's own directories, against a provider in memory; and the
  pickers, the photo picker, saving, bookmarks and opened files against
  scripted pickers. The packager's tests cover the intent filters.


**Model store:** AppRuntime's ModelStore contract. A guest keeps objects
of a CoreModel model across launches, and fetches, counts and changes
them, with `RuntimeModelStorage` and `Query`.

- **How:** `AndroidHostModelStore` gives AppRuntime's `HostModelStore` a
  CoreModel-SQLite database per store, `databases/<name>.sqlite`. Each
  database keeps the model it was made with, so a changed model is
  migrated, refused or reset by the contract's rules. A batch is one
  transaction (§6.7).
- **ExampleModel runs:** `Scripts/example-model.sh` packages AppRuntime's
  `ExampleModel` and drives it on the emulator, reading the database with
  `run-as` and Python's `sqlite3`.
  - The first launch makes two lists, as rows, and the file keeps the
    model.
  - To-dos are added, marked done, filtered, counted through their list,
    cleared and deleted, on screen and in their rows.
  - A to-do with no title is refused.
  - After a restart, in a new process, everything is as it was, and no
    list is made again.

  All 33 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 14 Swift tests run each kind of value, about 600
  requests, batches, opening, migration, indexes and errors against real
  databases in a temporary directory, and every request's answer is
  checked against CoreModel's own evaluator. One runs a guest's store
  through the runtime.

**Defaults:** AppRuntime's Defaults contract. A guest keeps small settings
across launches, with `UserDefaults` and `@AppStorage`.

- **How:** `AndroidHostDefaults` gives AppRuntime's `HostDefaults` a store
  over `SharedPreferences`, in a file of the app's own. Each key is marked
  with its value's kind, and bytes are kept as Base64 (§6.6).
- **ExampleDefaults runs:** `Scripts/example-defaults.sh` packages
  AppRuntime's `ExampleDefaults` and drives it on the emulator, reading the
  preferences file with `run-as`.
  - The launch count goes up at each start.
  - A toggle, a name and a theme show at once, are in the file, and are
    kept after the app goes to the background and starts again.
  - Reset removes every key, from the screen and from the file.

  All 19 checks pass both from the native slice and from `App.wasm`
  through wasm2c.
- **Unit tests:** 11 Swift tests cover the marked keys, one kind per key,
  empty values, the size limit, the keys listed, and Base64, against
  preferences in memory.

**Files:** AppRuntime's Files contract. A guest reads and writes its own
files, and reads its bundle's resources, with an `async` `FileManager`.

- **How:** `AndroidHostFiles` runs AppRuntime's `HostFiles` for the
  writable directories, in `filesDir` and `cacheDir`. The bundle is the
  APK's assets, read through the NDK's `AAssetManager` and listed from an
  index the packager writes (§6.5).
- **ExampleFiles runs:** `Scripts/example-files.sh` packages AppRuntime's
  `ExampleFiles` and drives it on the emulator, checking the files with
  `run-as`.
  - The welcome text comes from the bundle.
  - Notes are saved, listed, opened, exported and deleted, and their
    files are where §6.5 says.
  - After a restart, the notes are still there and `temporary` is empty.

  All 27 checks pass both from the native slice and from `App.wasm`
  through wasm2c. It needs AppRuntime from b3eb671,
  where `HostFiles` builds against bionic.
- **Unit tests:** 22 Swift tests cover the bundle's index, reads, ranges,
  listings and errors, copies out of the bundle, and the order of answers,
  against assets in memory and a temporary directory. The packager's
  tests cover the index and Gradle's ignored assets.

**Web views:** AppRuntime's WebKit contract. A guest makes a page, shows
it with `WebView(page)`, and hears its URL, title, progress, history and
failures. It also decides navigations and runs scripts.

- **How:** each page is an `android.webkit.WebView`, made off screen when
  the guest makes it. The player moves it into a `WebPageView` where a
  `WebView` node names it, and out again when the node goes, so the page
  stays loaded.
  - Swift (`AndroidHostWebKit`) turns `WebViewClient`'s and
    `WebChromeClient`'s pieces into the contract's events, each once and
    in order.
  - It also maps the errors, wraps scripts, and keeps a page off the
    network when the app doesn't declare `network`.
- **ExampleWeb runs:** `Scripts/example-web.sh` packages AppRuntime's
  `ExampleWeb` and drives it on the emulator.
  - swift.org loads, and its title shows.
  - A script counts its links.
  - A typed address loads example.com.
  - Back and Forward go between the two pages.

  All 11 checks pass from the native slice and through wasm2c. With
  `--no-network`, the app has no `INTERNET` permission and its page fails
  as not permitted.
- **composeui:** two fixes it needed came in
  [PureSwift/AndroidSwiftUI#79](https://github.com/PureSwift/AndroidSwiftUI/pull/79)
  (§9.2). The page now shares a stack with the views around it, and a text
  field submits on Enter.
- **Unit tests:** 17 Swift tests cover the event order, failures, the
  network rules, resources, scripts and the mappings, against a fake
  `WebView`.

**Surfaces:** AppRuntime's graphics contract. A guest draws with OpenGL
ES 2.0 in a `GLSurface` view, and gets that view's touches, mouse and
keys.

- **How:** `AndroidHostGraphics` draws with EGL from Swift, on the main
  thread, in a `TextureView` the player puts where the node is (§6.3).
  Frames come from the main thread's `AChoreographer`.
- **ExampleGL runs:** `Scripts/example-gl.sh` packages AppRuntime's
  `ExampleGL` and checks the screen's pixels on the emulator.
  - The triangle draws and turns.
  - A tap on it reverses the turn, and Space pauses it.
  - After Home and back, it draws again.

  All 12 checks pass both from the native slice and from `App.wasm`
  through wasm2c, which compiles AppRuntime's GL shim in.
- **Unit tests:** 24 Swift tests cover the frame loop, input delivery and
  the key tables, against a fake EGL. A lost context is unit-tested only:
  the emulator doesn't lose one.

**Phase 4:**

- **wasm2c.** `android-app` can make an ABI's library from `App.wasm`
  instead of a slice (`--engine wasm2c`, and by default for an ABI without
  a slice).
  - The packager runs WABT's `wasm2c` and AppRuntime's shim, compiles them
    with the NDK's clang, and seals the result like a slice, with
    `ld.lld` and `llvm-objcopy`. It then links it into `libapp.so` as it
    links a slice (§9.1.6).
  - ContractsCheck's 76 checks pass from its `App.wasm` on the emulator.
  - The translated code keeps the guest in its linear memory, so an
    arm64 APK without a native slice keeps heap pointer tagging on.
- **Background location.** The host's foreground service (`HostService`)
  runs while a `LocationManager` updates with background updates on and
  `authorizedAlways`, with a notification.
  - The packager declares the service, `FOREGROUND_SERVICE` and
    `FOREGROUND_SERVICE_LOCATION` for `location(.always)`.
  - ContractsCheck now has an `App.swift` manifest that declares it. The
    script picks "Allow all the time" in Settings, checks the service runs,
    sends the app to the background, and moves the GPS: the update
    arrives. All 78 checks pass.
  - Android lets an app start a foreground service only from the
    foreground, so it starts when the guest asks for background updates,
    not when the app leaves.
- **Background Bluetooth** uses the same service while a peripheral is
  connected, but runs only for a bundle whose `RTCapabilityOptions`
  declares it, which AppRuntime's manifest can't write yet (§9.1.5). It's
  unit-tested only.
- **Images from the bundle.** The packager copies `resources/**` images
  into `res/drawable-*`: 1x as `mdpi` (a point per pixel, as on iOS), `@2x`
  as `xhdpi` and `@3x` as `xxhdpi`, named `rt_` plus the name made safe.
  The adapter maps `Image(name)` the same way, so composeui finds them with
  Android's own density selection. TalkBack says the original name, once
  composeui uses its `label` (§9.2).
- **TalkBack checks.** `Scripts/example-ui.sh --run --accessibility`
  audits each screen's accessibility tree as TalkBack merges it:
  - every control has something to say;
  - no control sits inside another one the same size;
  - touch targets are at least 48 dp;
  - images have descriptions.

  It found that each swipeable list row was two TalkBack stops: the
  context menu standing in for swipe actions made a second clickable node.
  The fix is in composeui, and both screens now pass.
- **composeui's nodes:** `Grid`/`GridRow` and `SwipeActions`, and the fixes
  above, came in [PureSwift/AndroidSwiftUI#78](https://github.com/PureSwift/AndroidSwiftUI/pull/78).
  - The adapter maps `Grid`, `GridRow` and `SwipeActions` to them, in
    place of stacks and a context menu.
  - ExampleUI's check now also swipes a row and taps its Delete, which
    removes it, and checks that the About sheet's grid lines up its
    columns.
- **Not done: the ABIs on hardware.** The phone at hand is arm64-only,
  with no 32-bit support, and the Mac can't run x86_64 emulator images.
  wasm2c makes both ABIs from `App.wasm`, so the remaining work is a run on
  each.

**Phase 3:** the host implements every contract module of AppRuntime:
Device, Formatting, Location, Networking, Bluetooth (central), Motion and
NFC (reader), and the `Permissions` built-in over runtime permissions.
`Scripts/contracts-check.sh` packages `Examples/ContractsCheck`, a guest
that calls them all, and its 76 checks pass on the emulator (API 36, arm64).

- **How each module is built (§4):** the contract and its logic in Swift,
  over a small protocol for what it asks Android, so 113 Swift Testing
  tests check them on macOS against fakes. The Android calls are Kotlin
  classes in `:appruntime-contracts`; `AndroidHostApp` binds them with
  swift-java, and `…Natives` objects carry callbacks back, on the main
  thread. Motion reads the NDK's sensors from Swift, on the main `ALooper`.
- **How it differs from the plan:**
  - **No AndroidKit or AndroidBluetooth** (§9.3). A Kotlin class per module
    is a few hundred lines, needs no generated bindings, and keeps each
    JNI crossing coarse. `:appruntime-contracts` replaces the planned
    `:appruntime-callbacks`.
  - **Motion uses the NDK headers directly** through `CAndroidHost`, not
    swift-android-native; a C helper drains `ASensorEvent`s into plain
    structs.
  - **The URL contract** (`org.pureswift.network.URL`, which §6.2 missed) is
    swift-foundation's `URL` and `URLComponents`, in Swift.
  - **One module list:** `AndroidHostModules` is what `libapp.so` registers
    and what the packager validates against.
- **What the emulator check covers:**
  - Device's facts, the battery listener (the script changes the emulator's
    battery) and the orientation;
  - number, date, relative and locale formatting in fixed locales;
  - the location prompt (the script answers it), a one-shot fix and
    updates from the emulator's GPS, and the heading;
  - HTTPS GET, a redirect, a 100 KB upload with progress, Basic
    authentication, a 404, an unknown host, plain HTTP refused, and a
    cancel, against httpbin.org;
  - the Nearby devices prompt, the powered-on state and a scan;
  - the accelerometer, fused device motion, the barometer, and the
    physical activity prompt;
  - NFC records, and a session that fails with `unsupported` where there's
    no NFC.
- **What phase 3 found:**
  - **Host objects come back as proxies.** An object the host hands out
    (a peripheral, a tag, a credential) reaches the host again as a proxy
    for its handle. `HostObjects.own` finds the object behind it, as
    DarwinAppRuntime does; Basic authentication failed until it did.
  - **"Asked before" means "answered".** Marking a permission as asked
    when the prompt opened made a status read during the prompt say
    `denied`. Android has no "not determined", so the host keeps its own
    flag, set when the answer arrives; a dismissed prompt answers nothing.
  - **One prompt at a time.** Android drops a permission request made
    while another shows, so the check asks for each after the last.
  - **Plain HTTP fails with an `IOException`** whose message names
    cleartext, not `UnknownServiceException`; the error mapping reads the
    message. AppRuntime's manifest has no way to allow plain HTTP for a
    domain yet, so it's always refused on API 28+.
  - Android's `HttpResponseCache` has no eviction: clearing it deletes it
    and installs a new one.
- **Not covered on the emulator:**
  - Bluetooth connections and GATT: the emulator finds no peripherals. The
    GATT queue, MTU exchange, notifications and errors are unit-tested;
    they need a device and a peripheral.
  - NFC tags, which need a device with NFC.
  - The step counter, which the emulator lacks.
- **Known gaps:**
  - Cookies are in memory per session, for the default configuration too;
    digest authentication can't be answered; `HttpURLConnection` rejects
    `PATCH`.
  - Background location needs a foreground service (phase 4).
  - `retrieveConnectedPeripherals` doesn't filter by service: Android can't
    tell without connecting.
  - `ActivityRecognizer` is unavailable without Google Play services.

**Phase 2:** `android-app` packages ExampleUI's universal bundle in three
forms, and each runs:
- a debug APK (`android-app run` installs and starts it, and
  `Scripts/example-ui-check.py` passes against it);
- a signed, minified release APK, which passes the same check;
- an App Bundle.

- **Commands:** `validate`, `package` (`--release`, `--aab`, `--keystore`,
  `--alias`), `run` (`--device`, `--replace`) and `gradle`.
- **Signing passwords** come from `ANDROID_KEYSTORE_PASSWORD` and
  `ANDROID_KEY_PASSWORD` when Gradle runs, never from the command line or
  the generated project.
- **How it differs from §8:**
  - **No generated SwiftPM package.** The packager builds the host's own
    `app` product with `ANDROIDAPPRUNTIME_SLICE` set, in a scratch
    directory per app and ABI in the work directory. That's as incremental
    as a generated package, and has one less manifest to keep in step.
  - **No `:template` module.** The packager writes the app module itself:
    `build.gradle.kts`, the manifest, `res/` and `assets/rt/`. It includes
    the host's `:appruntime-ui` and `:appruntime-shell` from its checkout.
  - **Icons:** `icon.png` goes in `mipmap-xxxhdpi` only, and Android scales
    it down for the other densities. Adaptive icons come later.
  - **No URL scheme filters:** AppRuntime's manifest has no URL schemes yet.
- **What phase 2 found:**
  - androidx's graphics library brings its own `.so` for every ABI. Without
    `abiFilters`, an App Bundle would install on an x86 or 32-bit ARM
    device with no `libapp.so`, so the generated build limits it to the
    ABIs packaged.
  - A release is minified with R8. The shell's consumer rules, which keep
    `NativeHost` and `RenderSurface` for Swift, are enough: the release
    APK passes the UI check.
  - A debug run over an installed release fails on the signature, so `run`
    explains it, and `--replace` uninstalls the release first.
  - Sizes for ExampleUI, arm64 only: the debug APK is 83 MB (unoptimized,
    with symbols), the release APK 55 MB, and the App Bundle 19 MB. The
    Swift runtime libraries are most of it; linking them statically
    (decision 4) would shrink them.

**Phase 1:** AppRuntime's `ExampleUI` runs in the emulator from its universal
bundle, in a hand-made Gradle project (`Scripts/example-ui.sh --run`). It
renders through composeui, and taps, typing, the lazy list, navigation and
the system back gesture reach the guest and come back.

- **The host:**
  - `RuntimeHost` landed in AppRuntime (§9.1.2).
  - `AndroidHost` has the main looper (an `eventfd` and a `timerfd` on the
    main `ALooper`), its clock and the built-ins.
  - `AndroidHostUI` forwards the guest's bytes; `AndroidHostApp` is
    `libapp.so`'s natives.
- **The player** (`:appruntime-ui`):
  - `RenderCodec.kt` decodes the IR;
  - `IRAdapter.kt` builds composeui's tree, with stable callback IDs;
  - `RenderSurface.kt` keeps the guest's tree, patches subtrees, and is
    composeui's sink.
  - composeui's sources are compiled from an AndroidSwiftUI checkout
    (`ANDROIDSWIFTUI_PATH`), without the jextract bridge (§9.2).
- **The shell** (`:appruntime-shell`): `AppRuntimeApplication`,
  `AppRuntimeActivity` and `NativeHost`.
- **Tests:**
  - 14 Swift Testing tests on macOS: the looper's timers, `AppHost` and the
    renderer;
  - 15 desktop JVM tests: the codec, the adapter, and the events callbacks
    become;
  - `Scripts/example-ui-check.py` drives the app with UI Automator.
- **What phase 1 found:**
  - composeui's tree differs from the IR in its structure, not only its
    names. Navigation levels become screens, with toolbars and search
    fields lifted out. A presented sheet or alert must sit on its level's
    screen. Picker options are tagged, and colors are ARGB. The adapter
    does all of it, so composeui is unchanged.
  - Lazy grids aren't in composeui. `LazyGridView` fills the gap,
    registered through composeui's `ComposableRegistry`. composeui doesn't
    apply a registered view's modifiers, so a lazy grid's padding is lost
    until composeui does.
  - composeui wraps a frame's content to its size when the frame has an
    alignment, which the IR always sends. A `Color` or `Shape` would shrink
    to nothing, so the adapter drops the alignment for views that fill
    their frame.
  - `adb shell setprop log.tag.AppRuntime DEBUG` logs every tree and row
    the guest sends, as an outline.

**Phase 0:** `ExampleApp`'s `android-arm64-v8a` slice runs in the emulator
(API 36, arm64) from a bare Activity, and passes every check AppRuntime's
`Packages/LinkedSlice` test makes on macOS. That covers calls both ways,
every wire type, typed throws, identity, capabilities, and async tasks
resumed by the clock. What phase 0 found:

- **Swift 6.4.2 builds everything for Android.** The 6.4.2 Swift SDK for
  Android builds AppRuntime's host modules (`RuntimeCore`, `RuntimeNative`,
  `DynamicRuntime`, `DynamicUI`, the contract modules, `ExampleHost`),
  swift-java and AndroidKit for `aarch64-unknown-linux-android28`.
- **The slice fits bionic.** `ExampleApp`'s `android-arm64-v8a` slice
  imports only `abort`, `arc4random_buf`, `clock_gettime`, `free`,
  `malloc`, `memcmp`, `memmove`, `memset`, `posix_memalign` and `write`
  from libc, all in bionic at API 28. It links into `libExampleAppHost.so`
  with swift-java.
- **The arm64 slice needs heap pointer tagging off.**
  - The slice is compiled for `aarch64-unknown-linux-gnu` (AppRuntime's
    `guest.py`, for its Embedded concurrency modules). That target's
    Embedded stdlib keeps String's flags in a pointer's top byte.
  - Android 11+ tags heap pointers in that byte (`0xb4…`), so the slice
    took its own native strings for foreign ones and trapped in
    `String.UTF8View._foreignIndex(after:)`. The full runtime is built for
    Android, which leaves the top byte alone, so only the slice fails.
  - With `android:allowNativeHeapPointerTagging="false"`, every check
    passes. That flag is a workaround: the fix is a slice whose Embedded
    stdlib is built for an Android triple (§9.1). x86_64 has no tagging.
- **The 6.4.2 SDK needs NDK r30's `libc++_shared.so`.**
  - Its runtime is built with NDK r30's clang (`r574158c`; r29's is
    `r563880c`). `libswiftCore.so` uses `std::__hash_memory`, which r27's
    and r29's libc++ lack.
  - Its setup script accepts NDK r27 anyway, so the build succeeds and the
    library fails to load at run time. `Scripts/example-app.sh` checks
    every libc++ symbol the runtime needs when it stages the libraries.
  - With the SDK set up with NDK r30, `Scripts/example-app.sh --run`
    passes from a clean build.
- **The Swift runtime is dynamic for now** (decision 4).
  - Swift 6.4's build system passes `--static-swift-stdlib`, `-Xswiftc` and
    `-Xlinker` to the macOS builds of the package's macros too, and the
    macro links then fail.
  - The deprecated native build system keeps them apart, but the SDK has
    no static `_FoundationCShims` or `_FoundationCollections`, which
    swift-java's Foundation import needs.
  - The APK carries the SDK's runtime libraries instead (about 15, from
    `libswiftCore.so` to `libFoundationEssentials.so`; no ICU).
- **The SDK's toolset already links with `-z max-page-size=16384`**, so
  16 KB pages need nothing from the host.
- **Gradle 8.14 needs a JDK from 17 to 21.** `java_home -v 21` falls back
  to newer JDKs, so `Scripts/example-app.sh` checks each candidate's
  version.

This is the Android host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps, the counterpart of DarwinAppRuntime and LinuxAppRuntime. An AppRuntime
app is guest code only: a universal bundle with `App.wasm` and native
`libapp.a` slices (`android-arm64-v8a`, `android-armeabi-v7a`,
`android-x86_64`). This repository turns that bundle into an Android app.
It covers four parts:

- the **host runtime**: the Activity shell, the main looper, the runtime
  core behind `rt.h`, the built-in contracts, and the contract
  implementations over the Android SDK;
- the **SwiftUI player**: AndroidSwiftUI's Compose interpreter (`composeui`)
  behind an adapter for AppRuntime's render IR;
- **Bluetooth**, through PureSwift/AndroidBluetooth's bindings;
- the **packager**, `android-app`, which turns a universal bundle into a
  signed APK or App Bundle.

References like §7.6 point to `Documentation/DynamicRuntime.md` in
AppRuntime. The render IR is defined in `Documentation/RenderIR.md` there.

The plan builds on four existing projects:

| Project | What this host takes from it |
|---|---|
| [swiftlang/swift-java](https://github.com/swiftlang/swift-java) | JNI from Swift: `@JavaClass` wrappers, `@JavaImplementation` for `native` methods, jextract (JNI mode) for Kotlin → Swift calls, thread attachment, the cached app class loader |
| [PureSwift/Android](https://github.com/PureSwift/Android) (AndroidKit) | Generated bindings to `android.*`: `os`, `app`, `content`, `location`, `nfc`, `net`, `hardware` and others |
| [PureSwift/AndroidBluetooth](https://github.com/PureSwift/AndroidBluetooth) | Bindings to `android.bluetooth` and `android.bluetooth.le`; Kotlin callback adapters that forward to Swift event sinks |
| [PureSwift/AndroidSwiftUI](https://github.com/PureSwift/AndroidSwiftUI) | `composeui`, a Compose Multiplatform interpreter for a render tree almost identical to AppRuntime's; the `androidbridge` shell pattern and the main-looper posting |

## 1. Decisions

1. **The host is written in Swift, not Kotlin.**
   - AppRuntime's design (§2.3, §5) sketched Kotlin contract implementations
     behind a C JNI shim.
   - This plan uses the Swift-registry backend instead, as Darwin and Linux
     do. The host links `RuntimeCore` and `RuntimeNative`, and implements
     contracts in Swift against the generated proxies.
   - It calls Android through swift-java bindings: AndroidKit and
     AndroidBluetooth.
   - **Why:**
     - The runtime core, the startup checks, the module pattern and the tests
       stay the same as on the other two hosts.
     - The bindings already exist.
     - The JNI backend (DynamicRuntime.md §6) is never needed: it would cover only apps that
       call `android.*` directly, which this plan leaves out.
   - DynamicRuntime.md's Android rows (§2.3, §5, §6.1, §9.4) are updated to
     match (§9.1).
2. **Kotlin is used only where Android requires it:**
   - the `Application` and `Activity`;
   - the Compose player;
   - small adapter classes for Android's abstract callback classes
     (`ScanCallback`, `BluetoothGattCallback`, …).

   swift-java can't implement a Java interface or subclass a Java class at
   run time; it has no `Proxy` support. So every listener needs a Kotlin or
   Java class that forwards to Swift.
3. **The player is `composeui`, reached from Kotlin.**
   - The guest's IR bytes cross JNI as one `byte[]` per update.
   - A Kotlin decoder (`RenderCodec.kt`, a port of AppRuntime's
     `RenderCodec`) builds composeui's `ViewNode`s directly.
   - **Why:**
     - One JNI call per update, not one per node.
     - No dependency on AndroidSwiftUI's Swift evaluator: its `ComposeUI`
       target depends on `SwiftUICore`.
     - The adapter can be tested on the desktop JVM with no emulator.
4. **One shared library per ABI.**
   - `libapp.so` contains the host's Swift modules, the runtime core and
     the app's sealed slice (or its wasm2c output).
   - The Swift runtime should be linked statically, so the APK carries
     `libapp.so` and `libc++_shared.so`. For now it's dynamic: the SDK's
     runtime libraries go in the APK too (Status above).
   - The host uses `FoundationEssentials` only, keeping ICU's data out of
     the APK. Formatting goes through `android.icu.text` instead (§6).
5. **Minimum API 28 (Android 9).**
   - The Swift SDK for Android's triples are `…-linux-android28`, and
     AndroidKit's and AndroidBluetooth's CI start at 28.
   - The default `targetSdk` is 35.
   - AppRuntime's manifest examples say `minSDK: 26`. The packager raises
     a lower `minSDK` to 28 with a warning, and the examples change (§9.1).
6. **Toolchain: Swift 6.4 is required.**
   - The package's tools version is 6.4, and `.swift-version` pins 6.4.2,
     AppRuntime's.
   - It uses the matching Swift SDK for Android,
     `swift-6.4.2-RELEASE_android`, set up with NDK r30 (Status above).
   - Gradle needs a JDK from 17 to 21.
   - The upstream projects build with 6.3.x today; all of them build with
     6.4.2 too.

## 2. Scope

| In | Later |
|---|---|
| arm64-v8a (devices, Apple-silicon emulators) and x86_64 (Intel emulators, Chromebooks) | armeabi-v7a: the slice exists, but its sealed helpers haven't run on hardware |
| Native slices linked into `libapp.so` | wasm2c (AppRuntime's shim, as on Darwin and Linux); WasmKit for development |
| One Activity, one renderer | Multiple windows, split screen as separate scenes |
| `Renderer`, the built-ins, `BluetoothCentral`, Location, Device, Networking, Formatting | Motion, NFC, the Bluetooth peripheral role, background modes |
| Debug APKs, signed release APKs and AABs | Play upload, Play Feature Delivery |

## 3. Process model

```
┌──────────────────────────── APK ────────────────────────────────┐
│ Kotlin (classes.dex)                                            │
│   AppRuntimeApplication  → System.loadLibrary("app")            │
│   AppRuntimeActivity     → lifecycle, permissions, intents      │
│   composeui + IR adapter → Compose UI, events → native          │
│   callback adapters      → ScanCallback, GattCallback, …        │
│ ─────────────────────────── JNI ─────────────────────────────── │
│ lib/<abi>/libapp.so                                             │
│   AndroidHostApp: JNI_OnLoad, @JavaImplementation natives       │
│   AndroidHost: AppHost, MainLooper, clock, built-ins            │
│   contract modules: Bluetooth, Location, Device, …              │
│   RuntimeCore + RuntimeNative (rt_* symbols)                    │
│   the app's sealed slice (libapp.a) or its wasm2c output        │
│ lib/<abi>/libc++_shared.so                                      │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 The main thread

- **Everything that calls the guest runs on Android's main thread** (§6.4).
  Three kinds of call arrive there:
  - Kotlin → Swift calls: UI events, lifecycle, permission results, rows.
    These already arrive on the main thread.
  - Android listeners: `LocationListener` and `SensorEventListener` take a
    main `Looper` or `Handler`; `connectGatt` takes one on API 26+.
  - Work from other threads: Binder callbacks, the networking executor.
    These are posted to the main looper.
- **`MainLooper`** is the host's main loop, mirroring Linux's `MainLoop`. It
  has two parts:
  - a job queue other threads post to, woken through an `eventfd` that is
    registered with the main `ALooper` (swift-android-native's
    `AndroidLooper`);
  - timers on a `timerfd` registered the same way.
- **The clock** is `MainLooperClock`, the `HostClock`:
  - `now` reads `CLOCK_BOOTTIME`, which keeps counting through deep sleep,
    like Darwin's `mach_continuous_time`;
  - `schedule` uses the looper's timers.
- **No `DispatchQueue.main` and no main actor.** AndroidSwiftUI found that
  JNI from a native dispatch drain loses the app class loader: `FindClass`
  fails with `NoClassDefFoundError`. Looper callbacks run on the Java main
  thread, where the class loader is right. swift-java also caches the
  loader in `JNI_OnLoad`.
- **Every host→guest call** runs inside `GuestExecutor.enter`, as on the
  other hosts. The guest's update goes out before the call returns.

## 4. Modules

AndroidKit already uses names like `AndroidLocation`, `AndroidNFC` and
`AndroidOS`, and AndroidBluetooth is its own module, so this host prefixes
its modules with `AndroidHost`.

Each contract module is plain Swift: the contract, its mappings, and a
small protocol for what it asks Android (`DeviceSystem`, `LocationSystem`,
…), so `swift test` checks it on macOS against a fake. The Android calls are
Kotlin classes in `:appruntime-contracts`, and `AndroidHostApp` binds them
with swift-java. Motion reads the NDK's sensors from Swift, with no Kotlin,
and surfaces draw with EGL from Swift; Kotlin gives them a view and its
input.

| Module | Contents |
|---|---|
| `AndroidHost` | `AppHost` (the checks, the built-ins, the modules, `rt_main`), `MainLooper`, `MainLooperClock`, `AndroidPermissions` (the runtime permissions of §6.1), `AndroidBundle`, `HostObjects` (a host's own objects behind the proxies the guest passes back), `HostLog` |
| `AndroidHostUI` | The `Renderer` contract: it forwards `apply` / `replaceSubtree` bytes to Kotlin, and Kotlin's `event` / `rowCount` / `row` calls to the guest's `RendererDelegate` |
| `AndroidHostBluetooth` | `BluetoothCentral`, `BluetoothPeripheral`, `BluetoothService`, `BluetoothCharacteristic`, `BluetoothDescriptor`, `BluetoothAdvertisement` over `BluetoothLeScanner` and `BluetoothGatt`, with the GATT queue and scan record parsing in Swift |
| `AndroidHostLocation` | `LocationManager`, `Location`, `Heading` over `android.location` and the rotation vector sensor |
| `AndroidHostDevice` | `Device` over `Build`, `BatteryManager`, `PowerManager`, `Configuration`, `Settings.Secure` and the sensors |
| `AndroidHostNetworking` | `HTTPSession` and its values over `java.net.HttpURLConnection`; the URL contract over swift-foundation's `URL` |
| `AndroidHostFormatting` | `NumberFormat`, `DateFormat` and `LocaleInfo` over `android.icu.text` |
| `AndroidHostMotion` | `MotionManager`, `Altimeter`, `Pedometer` over the NDK's sensors (`ASensorManager`); `ActivityRecognizer` reports unavailable |
| `AndroidHostNFC` | `NFCReader`, `NFCTag` and NDEF over `NfcAdapter` reader mode |
| `AndroidHostGraphics` | `Surface` over EGL and `AChoreographer` (§6.3): `SurfaceHub` runs the frames and delivers input, `InputMapping` maps `MotionEvent`s and key codes |
| `AndroidHostWebKit` | `WebContent` over `android.webkit.WebView` (§6.4): `AndroidWebContent` turns the view's reports into the contract's events, and `WebMapping` maps errors, navigations, resources and scripts |
| `AndroidHostFiles` | `Files` (§6.5): `AndroidFiles` runs `HostFiles` for the writable directories, `BundleFiles` for the APK's assets and `DocumentFiles` for the documents the user gave (§6.8), on one queue |
| `AndroidHostDefaults` | `Defaults` (§6.6): `HostDefaults` over `AndroidDefaultsStorage`, which keeps values in `SharedPreferences` |
| `AndroidHostNotifications` | `Notifications` and `PushNotifications` (§6.9): AppRuntime's `HostNotifications` over `AndroidNotificationCenter`, which keeps scheduled requests and posts them through `NotificationPlatform` |
| `AndroidHostModelStore` | `ModelStore` (§6.7): `HostModelStore` over `SQLiteModelStorageProvider`, a CoreModel-SQLite database per store, with `Pushdown` deciding what SQLite answers |
| `AndroidHostClipboard` | `Clipboard` (§6.11): AppRuntime's `HostClipboard` over `AndroidClipboardPlatform`, which asks `ClipboardSystem` |
| `AndroidHostContacts` | `Contacts` (§6.14): AppRuntime's `HostContacts` over `AndroidContactDirectory`, which asks `ContactSystem` |
| `AndroidHostCalendars` | `Calendars` (§6.15): AppRuntime's `HostCalendars` over `AndroidCalendarStore`, which asks `CalendarSystem` |
| `AndroidHostSecrets` | `Secrets` (§6.12): AppRuntime's `HostSecrets` over `KeystoreSecretStore`, which asks `SecretSystem` |
| `AndroidHostAuthentication` | `WebAuthentication` (§6.12): AppRuntime's `HostWebAuthentication` over `AndroidWebAuthenticationPresenter`, which asks `AuthenticationSystem` |
| `AndroidHostMedia` | `MediaPlayback` (§6.10): AppRuntime's `HostMediaPlayback` over `AndroidMediaPlatform`, an `AndroidMediaEngine` per player over `MediaPlayerSystem`, and what's playing over `NowPlayingSystem` (§6.13) |
| `AndroidHostDocuments` | `Documents` (§6.8): `AndroidDocuments` and its grants over `DocumentPickerSystem`, the Storage Access Framework's pickers |
| `AndroidHostModules` | The list of every module, which `libapp.so` registers and the packager checks apps against |
| `AndroidHostApp` | `JNI_OnLoad` and the `@JavaImplementation` natives of the Kotlin shell, and each module's swift-java bindings. It links every module, plus `CRuntime` |
| `AndroidPackager`, `android-app` | The packager (§8) |

The Gradle side lives in `Android/`:

| Gradle module | Contents |
|---|---|
| `:appruntime-shell` | `AppRuntimeApplication`, `AppRuntimeActivity` (a `ComponentActivity`), `NativeHost` (the `external fun`s), `GraphicsSurface`, `WebPageNode` and `VideoPlayerNode` (the composables `GLSurface`, `WebView` and `VideoPlayer` nodes become), and `TextSelectionNode` (what a node with `textSelection` is in) |
| `:appruntime-ui` | The IR adapter: `RenderCodec.kt`, `IRAdapter.kt`, `RenderSurface` (composeui's `CallbackSink`). It depends on `composeui` |
| `:appruntime-contracts` | `HostContext`, and a class per contract module that calls the Android SDK (`DeviceSystem`, `PermissionSystem`, `FormattingSystem`, `LocationSystem`, `NetworkSystem`, `BluetoothSystem`, `NfcSystem`, `GraphicsSystem` with `GraphicsView`, `WebSystem` with `WebPageView`, `FileSystem`, which also gives the model store its directory, `DefaultsSystem`, `DocumentSystem`, `MediaSystem` over Media3's `ExoPlayer`, `NowPlayingSystem` with `NowPlayingService`, `NotificationSystem` with `NotificationReceiver`, `ClipboardSystem` with `ClipboardFileProvider`, `SecretSystem`, `AuthenticationSystem` with `AuthenticationRedirectActivity`, `ContactSystem`, `CalendarSystem`), with a `…Natives` object whose natives carry what Android reports back to Swift |

The Swift package depends on AppRuntime without its `GuestExports` trait,
like the other hosts. The slice's `rt_dispatch` and `rt_finalize` are then
the only copies linked (DarwinAppRuntime's `HostRuntime.md` §8).

## 5. Startup

1. **`AppRuntimeApplication.onCreate`** calls
   `System.loadLibrary("app")`.
   - `JNI_OnLoad` runs swift-java's setup: it adopts the VM and caches the
     class loader.
   - It also calls `MainLooper.install()` on the main thread.
2. **`AppRuntimeActivity.onCreate`** calls `NativeHost.start(activity,
   savedState)`. The app's keys come from the APK, not a file path:
   - `RTABIVersion`, `RTContracts` and `RTCapabilities` from
     `assets/rt/Info.plist`, which the packager copies from the universal
     bundle;
   - the id, version and build from `PackageManager`.
3. **Check the ABI and contract versions** (§7.6). A failure means a
   corrupt app, because the packager already checked. A debug build shows
   the error; a release build logs it and finishes the Activity.
4. **Set up the runtime:**
   - `NativeRuntime.shared.bindDirectly()`;
   - set the capabilities and the clock;
   - register the built-ins;
   - register each module whose contracts the app uses (§14's allowlist).
5. **Call `rt_main`.** When the guest calls `Renderer.make`, `AndroidHostUI`
   asks the Activity to `setContent { AppRuntimeRoot(store) }`. The first
   tree is in the store before `rt_main` returns.
6. **From then on**, the guest runs only when Android calls in: events,
   listeners, timers and lifecycle.

Configuration changes (rotation, dark mode, locale) must not restart the
guest:

- The Activity declares `android:configChanges` for them, and Compose
  re-lays out.
- If the system kills and recreates the Activity anyway, the guest keeps
  running in the process and the new Activity re-attaches to the existing
  renderer.
- A new process starts the guest from scratch. That matches iOS, where an
  app relaunched after termination starts over.

## 6. Contracts

The rules are the same as DarwinAppRuntime's `HostRuntime.md` §5:

- **Permissions first:** `make` and `authorizationStatus` never prompt.
- **Main thread:** delegates are called on the main thread only.
- **Ownership:** the implementation holds its delegate proxy strongly.
- **Errors:** each failure maps to the contract's error codes, with
  `unknown` for anything else, and is logged.
- **Identity:** one wrapper per Android object.

Each Android object Swift keeps is a swift-java global reference, released
with the wrapper.

### 6.1 Built-ins

| Built-in | Android |
|---|---|
| `Clock` | `MainLooperClock` (§3.1) |
| `Permissions` | See the table below. `status` uses `checkSelfPermission`, plus `shouldShowRequestPermissionRationale` and a "requested before" flag in `SharedPreferences` to tell `notDetermined` from `denied`. `request` calls `ActivityCompat.requestPermissions`, and the Activity forwards `onRequestPermissionsResult`. A capability the manifest doesn't declare is `denied`; one the device lacks (`FEATURE_BLUETOOTH_LE`, `FEATURE_NFC`) is `unavailable` |
| `Bundle` | `identifier` is the package name, `version` is `versionName`, `build` is `versionCode`, and `preferredLanguages` is `LocaleList.getDefault()`. Localized strings come from the bundle's `.lproj` folders, which the packager copies to `assets/rt/` and Swift reads through `AAssetManager`, so lookups behave as on the other hosts |
| `Application` | `state` comes from the Activity's lifecycle (resumed → active, started → inactive, stopped → background); `onTrimMemory(TRIM_MEMORY_RUNNING_LOW)` and above sends a memory warning; `ACTION_VIEW` intents (launch and `onNewIntent`) go to `open:url:` |

Permissions by capability:

| Capability | Runtime permissions |
|---|---|
| `bluetooth` | `BLUETOOTH_SCAN` (with `neverForLocation`) and `BLUETOOTH_CONNECT` on API 31+; `ACCESS_FINE_LOCATION` on API 28–30 |
| `location(.whenInUse)` | `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` |
| `location(.always)` | The above, then `ACCESS_BACKGROUND_LOCATION` as a second request (API 29+; Android requires the two steps) |
| `motion` | `ACTIVITY_RECOGNITION` (API 29+), for the step counter |
| `notifications` | `POST_NOTIFICATIONS` (API 33+) |
| `camera` | `CAMERA` |
| `nfc`, `localNetwork` | Install-time permissions with no prompt (`NFC`, `INTERNET`, `ACCESS_NETWORK_STATE`), so always `authorized` once declared |

### 6.2 Contract modules

| Contract | Android | Notes |
|---|---|---|
| `BluetoothCentral` and friends | `BluetoothLeScanner`, `BluetoothGatt`, through `:appruntime-contracts` | Not over AndroidBluetooth: neither its bindings nor its `GATT.CentralManager`, whose `async` and actor model doesn't fit a delegate contract on the main thread (§9.3). GATT operations are queued per device, one at a time, as Android requires (DynamicRuntime.md's host obligations). `connectGatt(…, TRANSPORT_LE, handler)` delivers `BluetoothGattCallback` on the main looper. `BluetoothPeripheral.identifier` is the MAC address. Scan modes map to `ScanSettings` (`SCAN_MODE_LOW_POWER`, `BALANCED`, `LOW_LATENCY`). The connection timeout is a main-looper timer. `GATT_*` statuses map to `BluetoothError` |
| `LocationManager` | `android.location.LocationManager` | The fused provider when available (API 31+), otherwise GPS and network. Updates go through `requestLocationUpdates(…, Looper.getMainLooper())`. Google Play services is not used, so apps work on any device. Accuracy maps to `ACCURACY_FINE` / `ACCURACY_COARSE` and the provider choice. Full accuracy is a precise-location request on API 31+ |
| `Device` | `Build`, `BatteryManager` (a sticky `ACTION_BATTERY_CHANGED` receiver while monitoring), `PowerManager`, `Configuration`, and the accelerometer and proximity sensors | `vendorIdentifier` is a name-based UUID of `Settings.Secure.ANDROID_ID`, which is scoped to the app's signing key, the closest match to `identifierForVendor`. The physical orientation comes from the accelerometer |
| `HTTPSession` | `HttpURLConnection` on a host-owned executor | It uses the platform's TLS, proxy and network-security config. Results, redirects and challenges are posted to the main looper. A redirect asks the guest on the main thread while the worker waits, so the guest is still called synchronously |
| Formatting | `android.icu.text.NumberFormat`, `DateFormat`, `SimpleDateFormat` (API 24+) | Formatters are cached per locale and style. ICU ships in the OS, so the APK carries no ICU data |
| Motion (phase 3) | `ASensorManager` (NDK), from Swift through `CAndroidHost` | Accelerometer, gyroscope, `TYPE_PRESSURE` for the altimeter, `TYPE_STEP_COUNTER` for the pedometer. Timestamps are already `CLOCK_BOOTTIME` nanoseconds. `ActivityRecognizer` needs Google Play services, so it reports `isAvailable == false` |
| `NFCReader` (phase 3) | `NfcAdapter.enableReaderMode` with the tag technologies requested | Reader mode needs the resumed Activity, so the reader session follows the lifecycle |

### 6.3 Surfaces

AppRuntime's `Surface` contract (DynamicRuntime.md §8,
Contracts/Graphics.md): the guest makes a surface, shows it with
`GLSurface(surface.identifier())`, and draws with GLES 2.0 in its
delegate's `frame`.

- **The view.** The adapter turns a `GLSurface` node into composeui's
  `Composable` node, named `org.pureswift.appruntime.GLSurface`.
  - The shell registers the composable: an `AndroidView` holding a
    `GraphicsView`, which is a `TextureView`.
  - A `TextureView` composes like any view, so SwiftUI's layering,
    clipping and opacity apply. A `SurfaceView` would sit in its own layer.
  - The node's modifiers wrap the view, as for any registered view.
- **One context.** One GLES 2.0 context serves every surface; each view's
  window gets an EGL window surface.
  - The context is made on the main thread when the first view arrives.
    It stays when views come and go, so leaving the screen loses nothing.
  - GL object names are shared between surfaces.
  - A wasm2c slice's GL shim tracks buffer bindings per context. With one
    context, its generation (`rt_gl_context_generation`) changes only when
    the context is replaced.
- **Frames.**
  - The main thread's `AChoreographer` calls `SurfaceHub` once per
    display refresh, while a visible view shows a live surface and the
    app is active.
  - For each view, the hub sends the waiting input, then `resize` if the
    size or scale changed. Then it makes the context current, calls
    `frame`, swaps, and clears the current context.
  - Timestamps are `CLOCK_BOOTTIME`, the `Clock` built-in's timeline.
    Choreographer and input times are `CLOCK_MONOTONIC`, and are moved
    over.
  - `AChoreographer_postFrameCallback64` is API 29, so it's looked up at
    run time. On API 28 the older callback's time is used on 64-bit ABIs.
- **A lost context.** `EGL_CONTEXT_LOST` from `eglMakeCurrent` or
  `eglSwapBuffers` gives every surface `contextLost`. A new context is
  then made, and every surface gets `contextRestored`.
- **Input.** Kotlin passes `MotionEvent`s and `KeyEvent`s raw, and
  `InputMapping` maps them (DynamicRuntime.md §8.6).
  - **IDs.** Touches and pens get Android's pointer ID plus 1, and the
    mouse is 0.
  - **Coalescing.** Moves are kept to one per pointer per frame. A
    pointer's waiting move goes out before its `down` or `up`.
  - **Keys.** A key's scan code names its position: it's a Linux key code,
    and is mapped to its HID usage. Keys without one, such as
    `adb shell input`'s, are mapped from their key code. Back, the volume
    keys and others the contract doesn't carry stay the system's.
  - **Focus.** A tap focuses the view. It has focus while it's focused in
    a window that has focus.
  - **No stuck input.** Losing focus, being hidden, the app going
    inactive or the view going all send `cancel` for each pointer in
    contact, then `focus(false)`.
  - **Pointer capture.** `View.requestPointerCapture` (API 26) gives
    relative mouse movement, summed into one `pointerDelta` per frame.
    `setPointerCaptured(true)` returns whether it asked: the view must have
    window focus, and a mouse must be connected. The answer arrives as
    `pointerCapture`.
- **Accessibility.** The `TextureView` isn't important for accessibility,
  because GL's pixels say nothing to TalkBack. The node's accessibility
  modifiers label the view around it.
- **Packaging.** For the `graphics` capability, the packager adds
  `<uses-feature android:glEsVersion="0x00020000" android:required="true"/>`
  (`0x00030000` for `.gles3`).
  - `libapp.so` links `libEGL` and `libGLESv2`, so a native slice's `gl*`
    calls resolve.
  - For wasm2c, the packager reads `App.wasm`'s imports. If any comes from
    `env.gl`, it compiles AppRuntime's `gl_shim.c` with `RT_GL_DIRECT`.

### 6.4 Web views

AppRuntime's `WebContent` contract (Contracts/WebKit.md): the guest's
`WebPage` makes a page, `WebView(page)` shows it, and the page reports
through `WebContentDelegate`.

- **A page is a `WebView`, made off screen.** `WebSystem` makes one per
  page, keyed by the page's `identifier()`.
  - It's made with a `MutableContextWrapper`. When a view shows the page,
    the wrapper's base becomes that view's Activity, so `alert`,
    `confirm` and `prompt` get Android's own dialogs.
  - JavaScript and DOM storage are on, and file and content access are
    off. New windows load in the same page.
- **Showing it.** The adapter turns a `WebView` node into composeui's
  `Composable` node, named `org.pureswift.appruntime.WebView`. The shell
  registers it as an `AndroidView` holding a `WebPageView`, a
  `FrameLayout`.
  - The `WebPageView` moves the page's `WebView` in, from wherever it was.
  - The node is `flexible`, as `GLSurface`'s is: in a stack, it takes the
    space its siblings leave, as SwiftUI's web view does (§9.2).
  - When the node goes (`onRelease`), the `WebView` comes out and the page
    stays loaded, with its history and scroll position.
  - Releasing the guest's `WebPage` destroys the `WebView`.
- **Events.** `AndroidWebContent` keeps what the guest last heard: the
  URL, title, loading state and progress, and the history. Android
  reports a load in pieces, so this sends each change once, in the
  contract's order.
  - `onProgressChanged` can come before `onPageStarted`. Either one starts
    loading.
  - `onPageFinished` can come twice, and also comes after a failure. It
    finishes a load only once, and only if the load didn't fail.
  - `doUpdateVisitedHistory` gives URL changes, including the History API
    ones, and the back and forward state.
  - `onReceivedTitle` gives the URL when a page has no title, so that
    counts as an empty title.
  - `onReceivedError` for the main frame becomes `didFailNavigation`, then
    the end of loading. `ERR_ABORTED` is a replaced or stopped
    navigation, so it isn't a failure.
- **Errors.** `WebViewClient.ERROR_*` codes map to `WebError.Code`, and so
  do Chromium's descriptions where the code is `ERROR_UNKNOWN`:
  `ERR_CLEARTEXT_NOT_PERMITTED` is `security`, and `ERR_NAME_NOT_RESOLVED`
  is `network`. A certificate error on the main frame is cancelled and
  reported as `security`.
- **Navigations.** `shouldOverrideUrlLoading` asks the guest, for every
  frame, and Android waits for the answer.
  - It isn't called for `loadUrl`, as the contract wants.
  - Its `hasGesture`, `isRedirect` and method give the navigation's kind.
    Android doesn't ask for back, forward or reload.
- **Without `network`:**
  - `setBlockNetworkLoads(true)`. The app has no `INTERNET` permission
    either.
  - `load` of a remote URL isn't started: it fails with `notPermitted`.
  - A navigation to a remote URL is refused without asking the guest, and
    fails the same way.
- **Resources.** `loadResource(path)` loads
  `https://appassets.androidplatform.net/resources/<path>`.
  `shouldInterceptRequest` serves that from `assets/rt/resources/`, where
  the packager puts the bundle's resources.
  - It serves only the loaded file's directory. Anything else on that host
    is a 404, and a path with `..` is refused.
  - A missing file fails with `badURL` before anything loads.
  - That host never reaches the network, so it isn't remote.
- **Scripts.** `evaluateJavascript` returns JSON, but gives `null` both
  for `undefined` and when a script throws. So the script runs inside a
  wrapper:
  - an indirect `eval` runs it in the global scope, with its last
    statement's value;
  - the wrapper then returns one string: the value as JSON, "no JSON
    value", or the exception's message.
  - On a page whose content security policy forbids `eval`, the script
    runs as it is. Then `null` and `undefined` both come back as no value,
    and exceptions are lost.
- **Pages ask for nothing.** Camera, microphone and location requests are
  denied.
- **When Android stops the page's renderer**, the page fails and its
  `WebView` is destroyed. The app goes on, but that page can't load
  again.

### 6.5 Files

AppRuntime's `Files` contract (Contracts/Files.md): the guest's
`FileManager` reads and writes the app's own files, and reads its bundle's
resources. No capability is needed.

| `FileDirectory` | Android |
|---|---|
| `documents` | `filesDir/Documents` |
| `data` | `filesDir/Data` |
| `caches` | `cacheDir/Caches` |
| `temporary` | `cacheDir/tmp`, emptied when the app starts |
| `bundle` | the APK's assets under `rt/resources`, read-only |

- **The writable directories are `HostFiles`.** `AndroidHostFiles` runs
  AppRuntime's POSIX implementation for them, as the Darwin and Linux
  hosts do, so the rules are the same code: atomic replacing writes,
  confined paths, the errors, and a move to another volume by copying.
  - Android's Auto Backup takes `filesDir`, where the user has it on, and
    leaves `cacheDir` out. The system may delete what's in `cacheDir`
    when space is short, as the contract says of `caches`.
  - `caches` is a folder in `cacheDir`, not `cacheDir` itself. The
    contract's table has `cacheDir`, but that's where `WebView` and the
    system keep their caches too, and `temporary` would be inside it
    (§9.1).
- **The bundle is the APK's assets.** Swift reads them through the NDK's
  `AAssetManager` (`CAndroidHost`), which any thread may use, from the
  `AssetManager` the shell's `FileSystem` hands over at start.
  - The size comes from `AAsset_getLength64`, which knows it without
    reading a compressed asset through. A range read seeks.
  - An asset has no modification date, so `modified` is 0.
  - The NDK lists a directory's files but not its subdirectories. So the
    packager writes `assets/rt/resources.index`, a line per file, and
    `list` and `attributes` come from that.
  - Writes, removes and moves out of the bundle fail with `readOnly`.
    Copies out of it work, a chunk at a time, so a large asset copies
    without being read whole.
- **One queue.** Every operation runs on one serial queue, the bundle's
  included, so a copy out of the bundle and a read of the copy happen in
  the order they were issued. Answers are posted to the main looper.
  - The guest's callback is held for the main thread to take out, so
    it's released there too, never by the worker's closure.
- **Gradle's ignored assets.** By default Gradle leaves out assets whose
  names start with `.`, and folders whose names start with `_`. The
  packager sets `androidResources.ignoreAssetsPattern` so that they're
  kept, as they are in the bundle on every other host. Version-control
  folders, `.DS_Store`, `Thumbs.db` and backup files (`*~`) are still left
  out, and the index leaves them out too.

### 6.6 Defaults

AppRuntime's `Defaults` contract (Contracts/Defaults.md): the guest's
`UserDefaults` and `@AppStorage`, which read and write at once, on the
main thread. No capability is needed.

- **`HostDefaults` over `SharedPreferences`.** AppRuntime's `HostDefaults`
  has the contract's rules (an empty key is refused, keys are sorted by
  their bytes). `AndroidHostDefaults` gives it `AndroidDefaultsStorage`,
  over the Kotlin `DefaultsSystem`.
- **A file of the app's own:**
  `shared_prefs/org.pureswift.appruntime.defaults.xml`, apart from
  anything else in the app. Android's Auto Backup takes it, where the user
  has it on.
- **Marked keys.** `SharedPreferences` has no byte type, so each key is
  stored with its kind:

  | Value | Stored |
  |---|---|
  | a string, such as `"true"` or `"0.5"` | `s:<key>`, as it is |
  | bytes | `d:<key>`, as Base64 |

  - Setting one kind removes the other, in the same edit.
  - Keys in the file without a mark aren't the guest's, and aren't
    listed. A marked key that holds something else, such as an `Int`,
    reads as no value.
- **Writes.** Each change is an edit that's applied: the value is there
  at once, and written in the background. Android waits for those writes
  when the Activity stops, so a value is there at the next launch, as the
  contract asks. `apply()` doesn't report a full disk, so only a value over
  64 KB is refused.
- **Made on first use.** The Kotlin object, and the file's first read, wait
  until the guest first reads or writes a value.

### 6.7 Model store

AppRuntime's `ModelStore` contract (Contracts/Persistence.md): a guest
opens a store by name with its model, and fetches, counts, inserts and
deletes objects, one at a time or in a batch. Each call is answered later,
on the main thread. No capability is needed.

- **`HostModelStore` over CoreModel-SQLite.** AppRuntime's
  `HostModelStore` runs a store's operations one at a time, off the main
  thread, and answers through the main looper. `AndroidHostModelStore`
  gives it `SQLiteModelStorageProvider`, whose stores are CoreModel-SQLite
  `SQLiteDatabase`s. It's Swift, so the Kotlin side only says where the
  databases go (`FileSystem.databaseDirectory()`).
- **A file per store:** `databases/<name>.sqlite`, in `getDatabasePath`'s
  directory, which Auto Backup takes where the app allows it. SQLite is
  the PureSwift/SQLite package's own build (SQLCipher, unencrypted), not
  `android.database.sqlite`.
- **The file keeps its model**, as JSON in the table `_appruntime_model`.
  No entity can have that name: `open` refuses it as `invalidModel`.
  Opening with another model compares them, in one order:
  - only entities or properties added or removed: the objects are copied
    into a new database of the new model;
  - anything else: `migrationRequired`, or, when the guest asked to reset,
    an empty database.

  A new database is made beside the old one, as `<name>.sqlite.new`, and
  renamed over it, so a store is never half made. The `SQLiteModelStorage`
  open before is closed, and fails anything still sent to it with
  `unavailable`.
- **A batch is one transaction.** `BEGIN IMMEDIATE`, each insert and
  delete in order, then `COMMIT`; on any error, `ROLLBACK`, so a failed
  batch changes nothing. CoreModel-SQLite wraps each insert and delete in a
  transaction of its own; PureSwift/SQLite 0.2.3 nests those as savepoints
  (§9.4).
- **What SQLite answers.** A request returns what CoreModel's in-memory
  evaluator returns (Persistence.md, "Requests"). CoreModel-SQLite 0.3.3
  disagrees with it on several things (§9.4), so `Pushdown` gives SQLite
  only what it answers the same:

  | SQLite | CoreModel, on what SQLite narrowed it to |
  |---|---|
  | an entity's own attribute compared with a constant by `==`, `<`, `<=`, `>`, `>=` (not a bool or bytes for the order), a to-one compared with an object or null by `==`, and `AND`, `OR` and `NOT` of those | sorts, string operators, options, `!=`, `IN`, arithmetic, modifiers, key paths through a relationship |

  An `AND` gives SQLite the conditions it can take and CoreModel the rest.
  A request SQLite answers whole, with no sort, keeps its limit and
  offset there; any other is evaluated after the fetch. A key path through
  a relationship fetches the other entities too.
- **Counts** are made without the limit and offset, which are applied to
  the number after (§9.4).
- **Indexes** the guest declares are made on the columns: attributes and
  to-ones. An index naming a to-many is left out.
- **Errors.** SQLite's codes become the contract's: a full disk is
  `outOfSpace`; a corrupt file or one that isn't a database, `corrupted`;
  no permission, a read-only file or one that can't be opened,
  `unavailable`. A file with no model table is `corrupted`.
### 6.8 Documents

AppRuntime's `Documents` contract (Contracts/Documents.md): pickers for
files, a folder, and a place to save; bookmarks; and files the app is
opened with. It needs `userFiles`, which prompts for nothing.

- **Android has no paths.** A document is a content URI, so AppRuntime's
  `HostDocuments`, which grants paths in `HostFiles`, doesn't fit. This
  host implements the four contracts itself (`AndroidHostDocuments`), and
  `Files` reaches a document through its own grants (`DocumentGrants` in
  `AndroidHostFiles`). Directories from 256 up are grants, as the contract
  says; releasing the guest's `DocumentGrant` ends one, and its directory
  answers `notPermitted`.
- **The pickers** are `ACTION_OPEN_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`
  and `ACTION_CREATE_DOCUMENT`, started from the Activity, whose
  `onActivityResult` hands the URIs to Swift.
  - One shows at a time: a second is `busy`. With no Activity, a picker is
    `notAllowed`.
  - Types become MIME types; an extension Android has no MIME type for
    shows every file, since a picker shows more, never fewer.
  - `.readWrite` asks for write permission when the file is picked. A
    document is writable when the app asked for it and the provider says
    it takes writes (`FLAG_SUPPORTS_WRITE`, or `FLAG_DIR_SUPPORTS_CREATE`
    for a folder).
  - A folder is the document at the top of the tree that was picked.
- **The photo picker** (`pickPhotos`, the contract's version 2) is the
  system's, `MediaStore.ACTION_PICK_IMAGES`, through androidx.activity's
  `PickVisualMedia`, which falls back to Google Play services' picker
  before Android 13 and to `ACTION_OPEN_DOCUMENT` for images and videos
  where there's neither.
  - It asks for no permission: the app holds no media permission and sees
    only what's picked.
  - A photo is read-only and can't be bookmarked (`unsupported`), as on
    every host. Its URI lasts until the app stops, so the host keeps no
    copy.
  - Its name is what the picker gives, the photo's media ID and an
    extension: Android hides the file's own name.
  - It answers as the other pickers do: one at a time, nothing when
    cancelled.
- **Saving** shows the save picker, which makes an empty document; the
  file is then copied into it on the files queue, and the new document is
  the guest's. The source is checked to be a file before the picker shows.
- **Files on a document.** `DocumentFiles`, on `AndroidFiles`' queue, has
  `HostFiles`' rules for a grant:
  - a file document is its directory's empty path;
  - a folder's paths are walked by display name, through
    `DocumentsContract`'s children; writes make the folders on the way;
  - the picked document itself can't be removed: `invalidPath`;
  - a replacing write is truncate-and-write (`"wt"`), since a provider has
    nothing atomic;
  - a range read seeks the descriptor, and reads through from the start
    where the provider's descriptor can't seek;
  - moves and copies with a document on either side are reads, writes and
    removes, so a move is a copy and then a remove.

  The Kotlin `DocumentSystem` makes the calls. Swift calls it from the
  files queue: its object is made on the main thread, where its class can
  be found. A `SecurityException` is `notPermitted`, a missing document
  `notFound`, and an I/O failure `unavailable`. It reports `unknown` as
  -1, since 0 is no error; so does `ClipboardSystem` (§6.11).
- **Bookmarks** are persisted URI permissions
  (`takePersistableUriPermission`), under a random key kept in
  `shared_prefs/org.pureswift.appruntime.documents.xml`. Android keeps 512
  for an app (128 before API 30): past that, `limitReached`. A document
  that can't be persisted, as one the app was opened with, is
  `unsupported`. Resolving a key whose permission is gone is
  `notPermitted`. Forgetting releases the permission when no other
  bookmark has it.
- **Opened with.** The packager writes an `ACTION_VIEW` filter, with
  `ACTION_EDIT` for an editor, for each of the app's document types that
  has MIME types (`RTDocumentTypes`), on `content` URIs. The Activity sends
  such an intent's URI to the guest's documents, writable for an
  `ACTION_EDIT` that grants writing. They wait, ungranted, until the guest
  listens. A provider that isn't a `DocumentsProvider`, as MediaStore or
  another app's `FileProvider`, gives what columns it has.

### 6.9 Notifications

AppRuntime's `Notifications` and `PushNotifications` contracts
(Contracts/Notifications.md). They need `notifications`.

- **`HostNotifications` over Android.** AppRuntime's `HostNotifications`
  checks each request, keeps responses until the guest listens, and turns
  records into values. `AndroidHostNotifications` gives it
  `AndroidNotificationCenter`, whose platform is the Kotlin
  `NotificationSystem`: Swift decides what to post and when, and Kotlin
  makes the calls.
- **Permission** is `POST_NOTIFICATIONS` from Android 13, asked once
  through `AndroidPermissions`, and the app's switch in Settings always:
  turned off, the status is `denied`. Before 13 there's only the switch.
- **Categories are channels,** `rt.c.<identifier>`, and a notification
  with none, or an unknown one, is in `rt.default`, named for the app.
  `passive` is `IMPORTANCE_LOW`, `active` `IMPORTANCE_DEFAULT`, and
  `timeSensitive` `IMPORTANCE_HIGH`. A sound of `.none` makes the channel
  silent. A named sound plays the default one: a channel takes a URI, and
  the bundle's files have none yet. The categories are kept, so a
  notification posted with the app closed has its buttons.
- **Showing.** Each notification is posted with its identifier as the tag.
  A tap and each button open the Activity with the notification in the
  intent; a text button is a `RemoteInput`. The Activity hands it to
  `HostNotifications.responded`, and a button's notification leaves the
  shade. A `.background` button opens the app too, until BackgroundTasks
  can run the guest with no window.
- **Scheduling.** A request with a trigger is kept in
  `noBackupFilesDir/org.pureswift.appruntime.notifications.json`, and its
  next time, from `HostNotificationTrigger.nextDate` in the device's time
  zone, is an `AlarmManager` alarm for `NotificationReceiver`. When it
  fires, the process starts if it has to; `libapp.so` is loaded by the
  Application, so Swift posts it, with no guest, and sets a repeating one
  again, skipping the times it missed. The packager declares the receiver
  for `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `TIME_SET` and
  `TIMEZONE_CHANGED`: every alarm is set again, a calendar trigger's at its
  time in the new zone, and what came due meanwhile is shown.
  - Alarms are exact (`setExactAndAllowWhileIdle`) when the user allows
    it, and within minutes otherwise. With `exactTiming` the manifest asks
    for `SCHEDULE_EXACT_ALARM`, and `requestExactTiming` opens its setting
    and answers when the app comes forward again.
  - An app keeps 500 alarms; past that, `add` fails with `limitReached`.
- **In front,** a notification is posted unless the guest's foreground
  presentation has neither `.banner` nor `.list`, and silently without
  `.sound`; the guest hears of every one while it runs.
- **Not here:** a number on the app's icon, which Android doesn't have
  (a notification's own number is its badge); and push, which needs
  Firebase Cloud Messaging and the app's `google-services.json`, so
  registering is `unsupported`.
- **Foundation.** `RuntimeNotifications` imports Foundation, for its
  calendar and named time zones, where this host's own code uses
  FoundationEssentials. `libapp.so` grows by about 2 MB.

### 6.10 Media players

AppRuntime's `MediaPlayback` contract (Contracts/MediaPlayer.md): a player
per `MediaPlayer`, `AudioPlayer` or `VideoPlayer`, which loads one source,
plays, pauses, seeks, and reports its state and time. It needs `audio`,
which prompts for nothing, and a URL needs `network`.

- **`HostMediaPlayback` over Media3.** AppRuntime's `HostMediaPlayback`
  checks and finds each source, remembers a play that came early, answers
  each seek once and stamps each time report with the guest's clock.
  `AndroidHostMedia` gives it an `AndroidMediaEngine` per player, which
  drives a Media3 `ExoPlayer` in the Kotlin `MediaSystem` by the player's
  identifier. What the player does comes back through `MediaNatives`.
- **Where a file is.** Android's files aren't all paths, so the host sets
  `HostMediaPlayback.findFile`:
  - the bundle's are `asset:///rt/resources/…`, which Media3 reads from
    the APK, checked against the bundle's index first;
  - a picked document's is its content URI (§6.8), found by asking its
    provider on the main thread;
  - the app's own are paths, as `HostFiles` has them.

  `loadData` writes the bytes to the app's cache, with an extension for
  their MIME type, and plays the file.
- **As media.** Each player has `USAGE_MEDIA` attributes and takes audio
  focus: another app's sound pauses it as `interrupted`, and Media3 plays
  again when focus comes back. Unplugged headphones pause it as
  `routeChanged`. A pause from the player's own controls is `user`; the
  guest's is `requested`. When the app goes to the background, every
  player pauses, as `background`.
- **Time.** While playing, the time and the buffer are reported at the
  guest's interval from a main-looper tick, and at once on a seek, a loop,
  and each start and stop.
- **Formats.** `canPlay` says `probably` for MP3, AAC in MP4, WAV and
  H.264 in MP4 or QuickTime, and `maybe` for WebM, Ogg, Opus, FLAC,
  Matroska and 3GPP, which need the device's decoder. HLS needs Media3's
  HLS module, which isn't included, so it's `no`.
- **`VideoPlayer`.** The IR adapter makes the node the shell's registered
  composable, `VideoPlayerNode`: a `PlayerView` showing the player the
  node names, with Media3's controls unless the node says `none`, fitted
  or zoomed to fill. When the node goes, the view lets the player go, and
  it keeps playing.
- **Playing on in the background,** and what's playing, are NowPlaying's
  (§6.13).
- **Not here:** a video's picture was shown with no source loaded; a real
  video wasn't played on the emulator.

### 6.11 Clipboard

AppRuntime's `Clipboard` contract (Contracts/Clipboard.md): copying and
pasting from code, and `textSelection`. No capability: Android guards a
read when it happens.

- **`HostClipboard` over `ClipboardManager`.** AppRuntime's
  `HostClipboard` checks images, sizes and files, and answers once.
  `AndroidHostClipboard` gives it `AndroidClipboardPlatform`, over the
  Kotlin `ClipboardSystem`.
- **What's copied.**
  - Text is a plain-text clip.
  - A link is one item with the text and the URI, described as both
    `text/plain` and `text/uri-list`.
  - An image is a file in `cacheDir/appruntime-clipboard`, the only one
    kept there, shared as a content URI through `ClipboardFileProvider`,
    a provider of the contracts module's own, so it can't clash with the
    app's.
  - `sensitive` sets `ClipDescription.EXTRA_IS_SENSITIVE`, which Android
    13 reads to keep the clip out of previews.
- **What's pasted.** A read gives the first item's text, or its URI's
  where it has no text; a URL only from a URI, never parsed from text; an
  image read through the `ContentResolver`, PNG or JPEG as it is and
  anything else Android decodes as PNG.
- **What there is,** for `available`, comes from the clip's description,
  which shows the user nothing. A read shows the system's note from
  Android 12, and works only while the app has focus: without it Android
  gives no clip, which is nothing to paste.
- **Files** for an image, to copy or to paste into, are found through
  `HostFiles.snapshot()`, which this host gives `AndroidWholeFiles`: the
  bundle is the APK's assets, and a picked document its content URI.
- **`textSelection`.** The IR adapter puts a node with the modifier in the
  shell's `TextSelectionNode`: Compose's `SelectionContainer`, so its text
  can be selected and copied with the platform's menu, or
  `DisableSelection` when it's turned off inside one.

### 6.12 Secrets and sign-in

AppRuntime's `Secrets` and `WebAuthentication` contracts
(Contracts/Secrets.md), in two modules as AppRuntime has them, checked
together with one example. `Secrets` needs `secrets`, which prompts for
nothing; a sign-in's redirect needs a scheme the manifest declares.

- **Secrets.** AppRuntime's `HostSecrets` checks keys and sizes and runs
  the store off the main thread. `KeystoreSecretStore` is the store, over
  the Kotlin `SecretSystem`:
  - one AES-256-GCM key, `org.pureswift.appruntime.secrets`, made in the
    Android Keystore the first time, which never leaves it;
  - each secret a file in `noBackupFilesDir/appruntime-secrets`, which
    Android never backs up and removes with the app. Its name is the
    SHA-256 of the secret's key; inside, after a fresh IV, the key and the
    value are encrypted together, so neither is readable;
  - a write goes to a new file renamed over the old one;
  - a Keystore key works while the device is locked, so both
    accessibilities read alike. A key the Keystore lost, or a file it
    can't open, is `unavailable`.
- **Sign-in.** AppRuntime's `HostWebAuthentication` checks the URL and the
  redirect and answers once. `AndroidWebAuthenticationPresenter` shows the
  page through the Kotlin `AuthenticationSystem`:
  - in a Custom Tab of the browser that offers them, ephemeral where it
    can be (androidx.browser 1.9); in the browser itself where none does.
    The contracts module's manifest declares the `queries` Android 11
    needs for an app to see the Custom Tabs service;
  - the packager declares `AuthenticationRedirectActivity`, with an
    intent filter for each of the manifest's `RTAuthenticationSchemes`.
    It hands the redirect to Swift and brings the app's Activity back
    over the browser;
  - the page was closed without a sign-in when the app comes back to the
    front with no redirect: Back, or the tab's close button. That's
    `canceledLogin`. The guest's `cancel` brings the app back over it.

### 6.13 Now playing

AppRuntime's NowPlaying additions to `MediaPlayback`
(Contracts/NowPlaying.md): what's playing, its buttons, and playing on in
the background. No contract of its own: `HostMediaPlayback` keeps which
player is the app's now-playing one and answers the buttons, and hands the
platform a `HostNowPlaying` at each change.

- **One session.** `AndroidMediaPlatform.showNowPlaying` tells the Kotlin
  `NowPlayingSystem`, which keeps one Media3 `MediaSession` for the app.
  Its player, `NowPlayingPlayer`, is a `SimpleBasePlayer` that plays
  nothing: its state is what Swift said, the title, artist, album, cover,
  position, duration and rate, and Media3 extrapolates the position while
  it plays. The `ExoPlayer`s stay the media players' (§6.10).
- **The buttons go back to Swift,** through `NowPlayingNatives`, as
  `HostMediaPlayback.remote`: play, pause, seeking and skipping answered on
  the player, as the user's; next and previous the guest's. Media3 maps
  the notification's buttons, the lock screen's and the media keys to
  them. It offers next and previous only where there's an item to go to,
  so with those buttons the player lists a stand-in on either side of
  what's playing, and going to one is the button.
- **The artwork** is read once when it changes: the bundle's from the APK's
  assets (`findFile`'s `asset:///`), a document's from its content URI, or
  the bytes.
- **The service.** The contracts module declares `NowPlayingService`, a
  `MediaSessionService`, started from the front with the first song. It
  gives the notification, the shade's and lock screen's controls, and
  the session to other controllers. A media notification needs no
  `POST_NOTIFICATIONS`.
- **Playing on** needs the manifest's `.audio(background: true)`. The
  packager then adds `foregroundServiceType="mediaPlayback"` to the
  service, with `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, and `HostMediaPlayback` doesn't
  pause a player that plays on. The service is in the foreground while
  it plays. Without the option the service never asks for the
  foreground, which Android would refuse without the type, and the app's
  players pause when it leaves the front, as before.
- **Interruptions** are the players' own audio focus (§6.10): Media3
  pauses for a call and plays again after it.
- **Not here:** `HostMediaPlayback.holdsApp`. Android keeps an app with a
  foreground service running, so nothing here stops an app that plays.

### 6.14 Contacts

AppRuntime's `Contacts` contract (Contracts/Contacts.md): the user's
address book, as the system keeps and syncs it. It needs `contacts`, read
and write unless the manifest says `.readOnly`.

- **`HostContacts` over `ContactsContract`.** AppRuntime's `HostContacts`
  checks access, refuses a write by an app that only reads and a contact
  with nothing in it, and runs the store off the main thread.
  `AndroidContactDirectory` is the store, over the Kotlin `ContactSystem`,
  and a person crosses between them as strings in a fixed order.
- **A person** is a row of `Contacts`, the unified contact, with
  `DISPLAY_NAME_PRIMARY` as the name Android made, and the `Data` rows of
  its raw contacts: the name (from the raw contact Android names them
  by), nickname, organization, birthday event, phones, emails, websites
  and postal addresses. Everyone is in `SORT_KEY_PRIMARY` order.
- **A search** is `Contacts.CONTENT_FILTER_URI`, Android's own, with its
  `limit`.
- **Labels** are Android's types where it has one for the contract's word
  (`TYPE_MOBILE` for `mobile`), in both directions, and `TYPE_CUSTOM` with
  the text for any other. A type the contract has no word for reads as
  Android's own label for it.
- **A postal address** has one country field on Android. A country's
  name is kept there; without one, its ISO code. Reading, two capital
  letters are the code, and a name gives its code in the user's language.
- **Saving a new person** is a raw contact on the device's own account,
  with its data rows, in one batch. **Saving a person there is** a batch
  on their writable raw contacts: one-of-a-kind rows (name, nickname,
  organization, birthday) are changed where they are, a list's value
  already there with its label stays, a new one goes to the first
  writable raw contact, and what the guest dropped is deleted wherever it
  is. A person whose raw contacts are all from an account whose sync
  adapter doesn't upload is `readOnly`. Rows the contract doesn't carry,
  as a photo or a note, aren't touched.
- **Access** is `READ_CONTACTS`, with `WRITE_CONTACTS` for an app that
  writes; the packager declares them. `requestAccess` is Android's
  dialog. The host reads the permissions again when the app comes back to
  the front, since the user may have changed them in Settings.
- **Changes.** Once access allows it, a `ContentObserver` on `Contacts`
  calls `HostContacts.storeChanged`, which joins a burst into one
  `didChange`.
- **Errors.** A `SecurityException` is `notAuthorized`, a failed batch
  `readOnly`. The Kotlin side reports `unknown` as -1, since 0 is no
  error.

### 6.15 Calendars

AppRuntime's `Calendars` contract (Contracts/Calendars.md): the user's
calendars and the events in them, as the system keeps and syncs them. It
needs `calendars`, `.full` or `.writeOnly`.

- **`HostCalendars` over `CalendarContract`.** AppRuntime's `HostCalendars`
  checks access, dates, ranges, spans and calendars, sorts, and runs the
  store off the main thread. `AndroidCalendarStore` is the store, over the
  Kotlin `CalendarSystem`, and calendars and events cross between them as
  strings in a fixed order.
- **A calendar** is a row of `Calendars`: its display name, its account
  (none for `ACCOUNT_TYPE_LOCAL`), its colour, and writable from
  `CAL_ACCESS_CONTRIBUTOR` up. Android has no default calendar, so the
  default is the first writable one that is its account's own
  (`IS_PRIMARY`), else the first writable one.
- **A range** is `Instances`, the provider's own expansion, without
  cancelled occurrences; the host keeps what overlaps the range, as the
  provider's takes in what only touches it. An occurrence from an
  exception crosses with its series' identifier and rule, the occurrence
  it replaces, and `isDetached`.
- **An event** is a row of `Events`. A series keeps its `RRULE` as the
  guest wrote it and its length as a `DURATION`; anything else keeps
  `DTEND`. An all-day event is stored at UTC midnights, in `UTC`, which is
  the contract's form already, and reads back with no time zone. A timed
  one without a zone takes the device's. Alarms are `Reminders` rows,
  `METHOD_ALERT`, replaced at each save. Availability is Android's busy,
  free or tentative; `unavailable` is busy.
- **One occurrence** (`span` 0) is an exception:
  `Events.CONTENT_EXCEPTION_URI` the first time, the exception's own row
  after. Removing one is an exception with `STATUS_CANCELED`. **This and
  the ones after** (`span` 1) is a new event from the occurrence, then an
  `UNTIL` on the series a second before it, with the exceptions from
  there deleted; from the first occurrence it's the whole series, without
  its exceptions.
- **Android's expansion has three gaps,** found on the emulator. Each
  save works around them:
  - A series and its exceptions are expanded together only when the
    series has a sync identifier. Without one, saving an exception
    re-expands that row alone and drops the series' other occurrences,
    a case the provider's source marks as a TODO. A calendar on the
    device alone (`ACCOUNT_TYPE_LOCAL`) has no sync adapter to give one,
    so the host acts as its sync adapter and gives the series a
    `_SYNC_ID` before its first exception. On a synced account, a
    series not yet uploaded is expanded wrongly until its sync adapter
    has synced it.
  - The provider expands again only when it's told the start, so every
    save writes `DTSTART` and the length with the rest.
  - An exception's own row is expanded with its series only when the
    update names the series (`ORIGINAL_ID`, `ORIGINAL_INSTANCE_TIME`).
  An exception takes its length as a `DURATION`; the provider refuses its
  `DTEND`.
- **Not kept:** the URL. Android's events have no column for it that an
  app can write, short of an extended property, which only a sync adapter
  can.
- **Access** is `READ_CALENDAR` and `WRITE_CALENDAR`, for either level:
  the provider reads nothing without `READ_CALENDAR`, not even the
  calendars a write-only app would add to. `HostCalendars` keeps a
  `.writeOnly` app from reading. The packager declares both;
  `requestAccess` is Android's dialog, which asks for the calendar as one
  thing. The host reads the permissions again when the app comes back to
  the front.
- **Changes.** Once access allows it, a `ContentObserver` on
  `CalendarContract.CONTENT_URI` calls `HostCalendars.storeChanged`, which
  joins a burst into one `didChange`.
- **Errors.** A `SecurityException` is `notAuthorized`, an
  `IllegalArgumentException` from the provider `unsupportedRecurrence`.
  The Kotlin side reports `unknown` as -1, since 0 is no error.

## 7. The SwiftUI player

### 7.1 Data flow

```
guest ─apply/replaceSubtree─► AndroidHostUI ─byte[]─► RenderCodec.kt ─► IRAdapter ─► composeui TreeStore ─► Compose
  ▲                                                                                       │
  └── RendererDelegate ◄── NativeHost.event / rowCount / row ◄── AppRuntimeSink ◄─────────┘
```

- **`apply`** replaces the tree in `TreeStore`. **`replaceSubtree`** uses
  `TreeStore.patch`.
- composeui keys its nodes by string ID, and the adapter uses the decimal
  node ID. Compose's identity then follows the guest's IDs, so native
  state survives updates: scroll position, focus, and a text field's
  selection.
- **Events.** composeui calls a `CallbackSink` with callback IDs taken from
  node props (`onTap`, `onSubmit`, `onIncrement`, …).
  - The adapter assigns those IDs. It keeps a table from each callback ID
    to a (node ID, event kind, value transform) entry, and rebuilds the
    entries for each subtree it replaces.
  - `AppRuntimeSink` turns a call into `NativeHost.event(nodeID, kind,
    payload)`, which is one JNI call into `RendererDelegate.event` inside
    `GuestExecutor.enter`.
  - The guest's answer is in the store before the call returns, as on
    Darwin.
- **Lazy rows.** composeui's `itemNode(id, index)` calls
  `NativeHost.row(listID, index)`. The bytes are decoded and cached by the
  list's `revision`, as the IR requires.
- **Control sync.** The IR's rule is "take the guest's value only when it
  differs from what was last rendered". composeui's `TextField` already
  re-syncs that way, and the adapter checks every control against it.

### 7.2 Vocabulary

composeui already renders most of the IR. The adapter maps names and
props, and a few nodes need work in composeui itself:

| IR | composeui | Work |
|---|---|---|
| `Text`, `Image`, `Label`, `Spacer`, `Divider`, `Color`, stacks, `ScrollView`, `Button`, `Toggle`, `TextField`, `Slider`, `ProgressView`, `Picker`, `List`, `Section`, `Form`, `DisclosureGroup`, lazy stacks and grids, `Menu`, `Link`, `TabView` | Same names | Props renamed, events wired |
| `Stepper` | `onIncrement` / `onDecrement` | The adapter sends `change(value ± step)`, clamped |
| `NavStack`, `NavLevel`, `ToolbarItem` | `NavStack` with a `titles` prop and `onPop` | The adapter flattens the levels. System back (predictive back on API 33+) sends `pop` |
| `Sheet`, `Alert` (`style: dialog`) | `Sheet`, `Alert`, `ConfirmationDialog` | Dismissal sends `change(false)` |
| `Tab` | Children of `TabView` | Title and `systemImage` become the tab item |
| `Grid`, `GridRow` | `Grid`, `GridRow` | Columns sized to the widest cell (added in phase 4) |
| `SwipeActions` | `SwipeActions` | Drag to reveal the actions; TalkBack offers them on the row (added in phase 4) |
| `Searchable` | `NavStack`'s `searches` | The adapter lifts each level's field onto its screen |
| `GLSurface` | `Composable`, registered by the shell | A `GraphicsView` the surface draws in (§6.3) |
| `WebView` | `Composable`, registered by the shell | A `WebPageView` the page's `WebView` moves into (§6.4) |
| Unknown types and modifiers | `EmptyView` | Logged once per type: the vocabulary is add-only |

Modifiers map one to one: `padding`, `frame`, `offset`, `background`,
`foregroundColor`, `tint`, `opacity`, `cornerRadius`, `border`, `shadow`,
`font` and its weight, `italic`, `lineLimit`, `multilineTextAlignment`,
`disabled`, `onTapGesture` and the accessibility modifiers.
`accessibilityIdentifier` becomes Compose's `testTag`, with
`testTagsAsResourceId` on, so UI Automator can find nodes by ID.

**Look:** Material 3 with dynamic color on API 31+. Named colors map to
Material's palette in light and dark. SF Symbol names map to Material icons
for the common ones; the rest show a placeholder, as on Linux.

## 8. The packager

`android-app` turns a universal bundle into an APK or AAB. Its commands
mirror `darwin-app` and `linux-app`:

```sh
android-app validate App.app
android-app package App.app --abi arm64-v8a --abi x86_64 [--engine native|wasm2c] [--release --keystore K --alias A] [--aab]
android-app run App.app            # installs on the running emulator or device with adb, and starts it
android-app gradle App.app         # writes the Gradle project, for Android Studio
```

The pipeline:

1. **Validate.** The bundle's contracts must all be implemented here, and
   its capabilities must match its contracts. The manifest must list an
   `android` platform, with `minSDK` raised to 28 if lower. Each requested
   ABI needs a slice, or `App.wasm` with `--engine wasm2c`.
2. **Build `libapp.so` per ABI.**
   - The packager generates a SwiftPM package that links `AndroidHostApp`
     with the slice. That is the same per-app approach as `darwin-app`, and
     it reuses the work directory between builds.
   - It builds with `swift build --swift-sdk swift-6.4.2-RELEASE_android
     --triple <arch>-unknown-linux-android28`. Flags for the Android link
     go in the generated package, limited to Android: Swift 6.4's build
     system would also apply command-line flags to the macOS builds of
     macros.
   - The SDK's toolset links with `-z max-page-size=16384`, the 16 KB page
     alignment Play requires for `targetSdk` 35 apps.
   - With `--engine wasm2c`, AppRuntime's `Scripts/wasm2c-shim.py build`
     makes the `libapp.a` instead. A module that imports `env.gl` gets
     AppRuntime's GL shim compiled in (§6.3).
3. **Write `AndroidManifest.xml`.** It holds:
   - the package, `versionCode` (the build number) and `versionName`;
   - `minSdk` and `targetSdk`;
   - the label (`@string/app_name`, per language) and the icon;
   - the permissions from §6.1;
   - `uses-feature` entries (`bluetooth_le`, `nfc`, `sensor.*`), marked
     `required` for capabilities marked `.required()`, and GLES 2.0
     (`glEsVersion`), always required, for `graphics`;
   - an intent filter for each URL scheme;
   - the app's `android.extraManifest`, merged into `<manifest>`.
4. **Resources.**
   - The icon is rendered at each mipmap density, plus an adaptive icon.
   - `res/values-<lang>/strings.xml` gets the app's name from
     `Manifest.strings`.
   - `assets/rt/` gets the bundle's `Info.plist`, the `.lproj` folders and
     the app's resources, with `resources.index` listing their files for
     `Files` (§6.5).
5. **Build.** The packager fills `:template` into a work-directory Gradle
   project and runs `assembleDebug`, `assembleRelease` or `bundleRelease`.
   It uses Gradle rather than raw `aapt2` / `d8` because Compose needs the
   Kotlin compiler plugin and Maven dependencies.
   - **Debug** builds use the debug keystore.
   - **Release** builds sign with the given keystore (`apksigner` v2/v3
     through Gradle's `signingConfig`), and run R8 with keep rules for the
     JNI entry points and the swift-java wrappers.

The packager only reads the universal bundle, and never compiles guest
Swift, which keeps apps and hosts versioned independently (§7.5).

## 9. Changes needed elsewhere

### 9.1 AppRuntime

1. **An arm64 slice that works with tagged pointers.** Phase 0 ran
   `ExampleApp`'s slice on bionic: its libc imports are all there, and
   `aarch64-linux.c`'s private glibc pieces don't get in the way. But the
   slice's Embedded stdlib, built for `aarch64-unknown-linux-gnu`, keeps
   String's flags in a pointer's top byte, which Android's heap tags use
   (Status). `android-arm64-v8a` needs an Embedded stdlib and concurrency
   runtime built for `aarch64-unknown-linux-android`, so the slice uses
   Android's spare-bit masks. Until then, hosts turn tagging off. An app
   packaged with the wasm2c engine doesn't need it: the packager turns
   tagging off only when the APK has a native arm64 slice.
2. **Shared host code.** `AppInfo`, `AppHost`'s checks and `HostModule` are
   the same on every host. LinuxAppRuntime's plan put off moving them into
   AppRuntime "once a third host needs them", and this is the third host.
   - **Done:** AppRuntime's `RuntimeHost` module has `AppInfo` (which reads
     property lists with `FoundationEssentials` too), `HostModule`,
     permission providers, `AppEntryPoints`, `AppCompatibility` (the
     checks), and the generic `HostPermissions` and `HostApplication`
     built-ins. This host uses it.
   - Darwin and Linux still have their own copies, and can move to it.
3. **Docs and examples.**
   - DynamicRuntime.md's Android rows (§2.3, §5, §6.1, §9.4) describe a
     Swift host, with Kotlin only for the shell, the player and the
     listener adapters.
   - The manifest examples' `minSDK: 26` becomes 28.
4. **Toolchain.** Host builds of `RuntimeCore`, `RuntimeNative`,
   `DynamicRuntime` and the contract modules for
   `aarch64-unknown-linux-android28` and `x86_64-unknown-linux-android28`,
   in AppRuntime's CI.
5. **Background Bluetooth in the manifest.** `AppManifest` can declare
   `location(.always)`, but has no option for Bluetooth in the background.
   This host already runs its foreground service for connected
   peripherals when the bundle's `RTCapabilityOptions` has
   `bluetooth: background = true`; `.bluetooth(usage:background:)` would
   write it.
6. **wasm2c for cross-compiled targets.** `wasm2c-shim.py build` compiles
   for Apple and Linux hosts only, so the Android packager runs `wasm2c`
   and the shim's `shim` command itself, and compiles and seals with the
   NDK. A `--cc`, `--ld` and `--objcopy` for `build` would let it use the
   shim's build.
7. **The graphics docs.** `Contracts/Graphics.md` and DynamicRuntime.md
   §8.6 say no host implements `Surface` yet. This one does now (§6.3).
8. **The files docs.** `Contracts/Files.md` says Android needs its own
   host side; this one has it (§6.5). Its table puts `caches` in
   `cacheDir` itself, and `temporary` inside it, in `cacheDir/tmp`. This
   host uses `cacheDir/Caches`, so the app's caches are apart from
   `WebView`'s and from `temporary`. The table could say so.
9. **The defaults docs.** `Contracts/Defaults.md` keeps bytes "under a
   marked key" on Android. This host marks both kinds (`s:` and `d:`), so a
   guest's key can't be mistaken for a mark (§6.6).
10. **The persistence docs.** `Contracts/Persistence.md` keeps Android's
   stores in `android.database.sqlite`, and says Android's SQLite takes no
   custom functions. This host is Swift over CoreModel-SQLite and
   PureSwift/SQLite's own build (§6.7), as the Linux column says. Its
   "For a host in Swift" section could also say what a `ModelStorage` over
   SQLite has to answer in memory, as `Pushdown` does.
11. **The documents contract.** `FileDirectory` is a struct now, so a
   picked document can be a directory. A copy out of the bundle into one
   goes through `FileEngine`'s moves and copies across documents (§6.8).
12. **The documents docs.** `Contracts/Documents.md` says Android needs a
   host of its own; this one has it (§6.8). Its Android row could add that
   a folder's paths are walked by display name, which two children can
   share, and that `HostFiles.path(of:path:)` has no Android counterpart:
   another contract handed a document asks `AndroidFiles.contentURI(of:path:)`.
   Its photo picker section could add that Android's picker gives a
   photo's media ID, not its file's name.
13. **The notifications docs.** `Contracts/Notifications.md` says Android
   implements the contracts itself, not being written in Swift; this host
   is, and uses `HostNotifications` (§6.9). `RuntimeNotifications` could
   import FoundationEssentials where it can, as the rest of `RuntimeHost`
   does.
14. **The media docs.** `Contracts/MediaPlayer.md` says Android implements
   the contract itself, not being written in Swift; this host is, and
   uses `HostMediaPlayback` with `findFile` (§6.10).
15. **The clipboard docs.** `Contracts/Clipboard.md` says Android needs
   its own platform; this host has it, over `HostClipboard` (§6.11).
16. **The secrets docs.** `Contracts/Secrets.md` says no host has a
   keychain or a browser behind it yet; this one has both (§6.12). Its
   Android row could add that the app needs a `queries` entry to see the
   Custom Tabs service.
17. **The now-playing docs.** `Contracts/NowPlaying.md` says Android needs
   its own; this host has it, over `HostMediaPlayback` (§6.13). Its
   Android row says the `MediaSessionService` holds the `ExoPlayer`; here
   the session holds a stand-in player, so that the buttons go through
   `HostMediaPlayback.remote`. Its manifest table could add that the
   service is declared for every app, and only its type depends on
   `background`.
18. **The contacts docs.** `Contracts/Contacts.md` says no platform host
   has an address book behind it and none of its per-host notes has been
   tried; this one has, on Android (§6.14). Its Android row could add that
   `RAW_CONTACT_IS_READ_ONLY` isn't a column of `RawContacts`, so a
   read-only raw contact is one whose account's sync adapter doesn't
   upload, and that an address has one country field, which keeps the
   ISO code where there's no name.
19. **The calendar docs.** `Contracts/Calendars.md` says no platform host
   has a calendar store behind it yet; this one has, on Android (§6.15).
   Its manifest table gives Android's `.writeOnly` as `WRITE_CALENDAR`
   alone. But the provider reads nothing without `READ_CALENDAR`, not
   even the calendars to add to, so this host declares both and keeps the
   app from reading. Its Android row could add three things. A series
   needs a sync identifier before its exceptions expand with it, which a
   host gives one on a calendar with no sync adapter. An exception takes
   its length as a `DURATION`. And Android keeps no URL for an event.
8. **The web docs.** `Contracts/WebKit.md` says no host implements
   `WebContent` yet, and that no real engine has loaded a page for
   ExampleWeb. This one does now (§6.4). Its Android row could also say
   that `evaluateJavascript` needs a wrapper to tell `undefined` and
   exceptions from `null`.

### 9.2 AndroidSwiftUI

- `composeui` must be usable without the Swift evaluator.
  - Its Gradle module depends on `:swiftbridge`, which runs `swift build`
    for jextract. Only `SwiftUIHostView.kt` uses that bridge.
  - For now `:appruntime-ui` compiles composeui's sources from a checkout,
    leaving that file out.
  - Better: a composeui module without the bridge, published as a Maven
    artifact.
- New nodes: `Grid` / `GridRow` and `SwipeActions` (§7.2). `Searchable`
  needs no node: composeui's `NavStack` already renders the adapter's
  search fields.
  - **Done:** [PureSwift/AndroidSwiftUI#78](https://github.com/PureSwift/AndroidSwiftUI/pull/78)
    added `Grid`, `GridRow` and `SwipeActions`, applies a registered view's
    modifiers (the lazy grid's padding), gives `Image` a `label`, and keeps
    `ContextMenu` to one TalkBack stop with its items as custom actions.
    The adapter uses them, so this host needs composeui from that merge
    on.
- **Flexible views, and submitting fields.**
  **Done:** [PureSwift/AndroidSwiftUI#79](https://github.com/PureSwift/AndroidSwiftUI/pull/79)
  has two fixes, and this host needs composeui from its merge on.
  - A stack child with a `flexible` prop gets `Modifier.weight`, so a web
    view or GL surface takes the space its siblings leave, as in SwiftUI.
    `fillMaxSize` took it all, and the views after it got none.
  - A text field with `onSubmit` and no `submitLabel` asks for
    `ImeAction.Done`. It used `ImeAction.Default`, which no
    `KeyboardActions` callback hears, so `onSubmit` never fired.
- **Sheets in dark mode.**
  [PureSwift/AndroidSwiftUI#77](https://github.com/PureSwift/AndroidSwiftUI/pull/77)
  added `preferredColorScheme`, and wraps each sheet in its own theme.
  - In a host that sets its own `MaterialTheme`, as this one does, sheets
    came out light in dark mode, in Material's baseline colors.
  - [#80](https://github.com/PureSwift/AndroidSwiftUI/pull/80) (open)
    keeps the presenting palette in sheets that don't prefer another
    scheme. Until it merges, composeui's `master` has this problem.
- `SwiftBridge.sink` is global, which is fine with one renderer per
  process. Multiple scenes would need a sink per `TreeStore`.

### 9.3 AndroidBluetooth, AndroidKit, swift-java

**Not needed after phase 3.** The contract modules call the Android SDK
from small Kotlin classes (`:appruntime-contracts`) instead of
AndroidBluetooth's and AndroidKit's generated bindings, so the host needs
nothing from either, and only swift-java's core. What follows was the plan
for using them.

- **AndroidBluetooth:**
  - The Kotlin `ScanCallback` and `BluetoothGattCallback` adapters move
    from `Demo/` into a library module, so hosts can depend on them.
  - The `connectGatt` overload that takes a `Handler` is bound, if it isn't
    already.
  - Its permission check covers `BLUETOOTH_CONNECT`.
- **AndroidKit:** the classes this host needs and doesn't find yet are
  added through wrap-java:
  - `ComponentActivity`;
  - `ActivityCompat`;
  - `LocaleList`;
  - `android.icu.text`;
  - `HttpURLConnection` (from swift-java's `JavaNet`).
- **All three, and swift-android-native,** must build with Swift 6.4.2 and
  the 6.4.2 Android SDK. The upstream projects are pinned to `main` and
  `master` branches today, so this host pins revisions in
  `Package.resolved`.

### 9.4 CoreModel-SQLite and SQLite

- **SQLite 0.2.3** nests `transaction()` as a savepoint when one is open
  ([PureSwift/SQLite#7](https://github.com/PureSwift/SQLite/pull/7)), so a
  batch is all or nothing (§6.7).
- **CoreModel-SQLite 0.3.3** answers some requests differently from
  CoreModel's evaluator. `Pushdown` keeps them from SQLite; fixed there,
  more of a request could go to SQLite:
  - `count` puts the limit and offset on `SELECT COUNT(*)`, whose one row
    an offset skips, and a debug build traps;
  - an empty `OR` is true;
  - nulls sort first, where CoreModel orders them as equal to anything;
  - `beginsWith`, `contains` and `like` ignore case, through `LIKE`;
  - `IN` against a string matches nothing;
  - a key path through a to-one, such as `team.name`, matches nothing.

## 10. Testing

- **Swift logic with no JNI:** the error tables, the permission and
  capability mapping, UUID and scan-record parsing, the GATT queue,
  `AppInfo` and the startup checks. These run with `swift test` on macOS,
  against fakes, the way Darwin and Linux test their mappings.
- **The IR adapter:** `RenderCodec.kt` is checked against byte fixtures
  that AppRuntime's `RenderCodecTests` write. The adapter and composeui are
  tested with Compose's desktop UI tests (`desktopTest`), as composeui
  already does, so no emulator is needed.
- **On the emulator:**
  - the JNI paths (startup, looper, clock, permissions, location with a
    mock provider, networking against a local server) run as
    instrumentation tests;
  - `ExampleUI` end to end: UI Automator finds nodes by
    `accessibilityIdentifier`, taps, types and navigates, and takes a
    screenshot of each screen.
  - `ExampleGL` (`Scripts/example-gl.sh`), by its pixels: it draws, turns,
    takes a tap and a key, pauses, and draws again after Home. This runs
    from both the slice and wasm2c.
  - `ExampleWeb` (`Scripts/example-web.sh`): a page loads, a script runs
    in it, an address loads another page, and back and forward work.
    `--no-network` checks that an app without the capability loads
    nothing remote.
  - The local arm64 `android-36` image covers this. CI uses API 28 and 35
    images, x86_64 on Linux runners.
- **Hardware:** Bluetooth and NFC need a device, so they get manual runs.

## 11. Phases

0. **Toolchain spike.**
   - Install the Swift 6.4.2 Android SDK.
   - Build AppRuntime's host modules, swift-java and AndroidKit for
     `aarch64-unknown-linux-android28`.
   - Link `ExampleApp`'s `android-arm64-v8a` slice into a `.so`, load it
     from a bare Activity on the emulator, and run `rt_main`.
   - This proves the slice on bionic and the 6.4.2 stack (§9.1.1).
   - `Scripts/example-app.sh` does it: it builds the slice, links it into
     `libExampleAppHost.so` (`Sources/ExampleAppHost`), stages the runtime
     libraries, builds `Android/example-app`, and with `--run` starts it on
     the emulator. It checks the report against the same lines as
     AppRuntime's `Packages/LinkedSlice` test.
1. **Host runtime and player.**
   - `RuntimeHost` lands in AppRuntime.
   - Build `AndroidHost`, `AndroidHostUI`, `AndroidHostApp`, the shell and
     the IR adapter.
   - Done when `ExampleUI` runs on the emulator from a hand-made Gradle
     project: it renders, and taps, typing, the lazy list and navigation
     reach the guest and back.
   - `Scripts/example-ui.sh --run` does it:
     - it builds the bundle with `guest.py`, links its slice into
       `libapp.so`, stages the runtime and `assets/rt/Info.plist`, and
       builds `Android/example-ui`;
     - `Scripts/example-ui-check.py` then drives the app.
2. **Packager.** `android-app validate`, `package` (debug APK, then signed
   release APK and AAB), `run` and `gradle`. Done when `ExampleUI` packages
   from its universal bundle and runs.
   - Done: `Sources/AndroidPackager` and `Sources/AndroidAppTool`, with 24
     Swift Testing tests that run the packager's steps with a fake command
     runner.
3. **Contracts:**
   - Bluetooth, Location, Device, Networking and Formatting;
   - then Motion and NFC.

   Each is unit-tested through its mappings and run on the emulator where
   Android allows it.
   - Done: every module, with 113 Swift tests in all, and
     `Scripts/contracts-check.sh`, whose 76 checks pass on the emulator.
4. **More:**
   - wasm2c;
   - the x86_64 and armeabi-v7a ABIs on hardware;
   - composeui's missing nodes;
   - images from the bundle;
   - TalkBack checks;
   - background location and Bluetooth (foreground services).
   - Done, but for the ABIs on hardware: no x86_64 or 32-bit ARM device was
     at hand (Status).

## 12. Open questions

- **Gradle in the packager.** Requiring Gradle and a JDK on the build
  machine is heavy for a packager. One alternative: ship the shell, the
  adapter and composeui prebuilt as `classes.dex` plus resources, and build
  the APK with `aapt2`, `zipalign` and `apksigner` only. That is faster and
  has no Maven at package time, but the prebuilt dex has to be versioned
  with the host. Gradle comes first because it's the shortest path.
- **Process death.** Android may kill the process in the background. The
  guest has no state restoration contract, so it starts over, as on iOS.
  `onSaveInstanceState` could later carry a guest-provided blob, which
  would need a new `Application` method.
- **Peripheral role.** AndroidBluetooth binds `BluetoothGattServer` and the
  advertiser, but no contract covers the peripheral role yet.
- **Play services.** This plan avoids it. An optional module could use the
  fused location provider and activity recognition on devices that have
  it.
