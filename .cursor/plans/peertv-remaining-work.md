# PeerTV — remaining work

Handoff plan from a review + implementation session. The first batch of changes is **done but uncommitted** (17 files, builds cleanly). This file describes what's left.

## Ground rules

- **Build** (must run outside the Cursor sandbox — the Swift macro plugin server and simulator service fail inside it):
  ```sh
  xcodebuild -project PeerTV.xcodeproj -scheme PeerTV -sdk appletvsimulator \
    -destination 'generic/platform=tvOS Simulator' -derivedDataPath .derivedData \
    -configuration Debug CODE_SIGNING_ALLOWED=NO build
  ```
- **New files must be added to `PeerTV.xcodeproj/project.pbxproj` by hand** (objectVersion 56, no synchronized folders). Prefer adding types to existing files.
- tvOS 17 deployment target, Swift 5 language mode, no third-party deps.
- Match surrounding style: UIKit in the player, SwiftUI elsewhere, `UIAlertController` action sheets for player menus (see `presentSpeedMenu` / `menuTitle(_:selected:)` in `PlayerLoaderView.swift`).
- Nothing has been run on a device/simulator yet — see "Verification" at the bottom.

## Already done (uncommitted)

- Instance search / own-channel listing / remote-video import only send `include` + non-public `privacyOneOf` for staff. `SessionStore.useBroadHomeVideoListing` renamed to `canSeeAllVideos`; `Endpoint.searchVideos` gained `includeAllPrivacy: Bool = false`.
- `HomeViewModel` `loadGeneration` counter drops results from superseded loads.
- Tile perf: `DownloadManager.downloadedVideoIds` (published separately), `isDownloaded` is a set lookup (internal download decisions use `hasValidLocalFile`), `VideoCardView` observes only that set, shared `PeerTubeDate` formatters (in `Video.swift`), in-memory cache in `PlaybackPositionStore`.
- `ImageCache.load(_:)`: shared in-flight requests, off-main decode (`byPreparingForDisplay`), dedicated `URLSession` with 200 MB disk cache; storyboard sheets pre-decoded.
- Now Playing: `NowPlayingMetadata` + `PlayerCoordinator.applyNowPlaying(_:)` set `AVPlayerItem.externalMetadata`; copied across quality swaps, rebuilt on playlist transitions.
- Remembered playback speed: `PlayerSettings.playbackSpeed` (saved from the Speed menu only, not the hold-for-2x toggle); `AVPlayer.defaultRate` follows `currentSpeed` (set in `adoptPlayer`, `setSpeed`, `toggleSpeedHold`, coordinator `init`).

---

## 1. Chapters

**API (confirmed from PeerTube source):** `GET /api/v1/videos/{id}/chapters` → `{ "chapters": [ { "timecode": 0, "title": "Intro" }, … ] }`. Public, no auth. Instances older than PeerTube 6 return 404 — treat any failure as "no chapters".

**Model / endpoint**
- `Video.swift`: `struct VideoChapter: Decodable { let timecode: Double; let title: String }` and `struct VideoChaptersResponse: Decodable { let chapters: [VideoChapter] }`. Add a helper that returns the index of the last chapter with `timecode <= time`.
- `Endpoint.swift`: `case videoChapters(id: String)` → `/api/v1/videos/\(id)/chapters`.

**Coordinator (`PlayerLoaderView.swift`, `PlayerCoordinator`)**
- `fetchChapters(for:)` modeled on `fetchStoryboards(for:)` (guard `videoId == id` before installing). Call from `init` and from `transitionToNextPlaylistItem` (clear first with `transportBar?.setChapters([])`).
- `presentChaptersMenu()`: action sheet, one row per chapter `"12:34  Title"`, current chapter marked with `menuTitle(_:selected:)` and set as `preferredAction`; selecting calls `transportBar?.seek(to: chapter.timecode)`.
- Pass `onChaptersTapped: { [weak self] in self?.presentChaptersMenu() }` into `TransportBarController`.

**Transport bar (`TransportBarOverlay.swift`)**
- `FocusableTrackControl`: `var chapterStartTimes: [TimeInterval]`. Marker views live **inside `trackContainer`** above the fills (so they clip to the rounded track): dark gaps (~4pt wide, `UIColor.black.withAlphaComponent(0.55)`), `autoresizingMask = .flexibleHeight` so they follow the focus height animation. Position them in `updateFill()` by frame; skip `timecode <= 0`; hide when duration unknown. Include them in `setChromeAlpha` only if they're outside `trackContainer`.
- `TransportBarOverlayView`: `chaptersButton` (`makeIconButton(symbol: "list.bullet.rectangle")`), `showsChaptersButton` property, add to `buttonStack` after `captionsButton`, hidden by default, accessibility label "Chapters".
- `TransportBarController`: new `onChaptersTapped` init param + `chaptersPressed` selector; entry in `presentQuickOptions()` when `bar.showsChaptersButton`; `func setChapters(_:)` (store, set marker times, toggle button); public `func seek(to seconds:)` using the same seek as `seekBy(seconds:)` plus `showBarAndResetTimer()`.
- `ThumbnailPreviewView`: optional caption label under/over the image; `showThumbnailPreview(at:)` sets it to the chapter title at that time.
- **Do not clear chapters in `detach()`** — quality switches call `detach()`/`attach()` on the same video.

## 2. Faster playlist autoplay (prefetch next item)

All in `PlayerCoordinator`.
- Extract the "fetch detail → decode → `PlayerPresenter.urlWithHLSTokenIfNeeded` → `AVPlayerViewControllerRepresentable.makeAsset`" part of `transitionToNextPlaylistItem` into `@MainActor private static func preparePlaylistItem(videoId:queue:) async throws -> PreparedPlaylistItem` (`video`, `url`, `asset`).
- `private var nextItemPrefetch: (videoId: String, task: Task<PreparedPlaylistItem?, Never>)?`
- `prefetchNextPlaylistItemIfNeeded()`: when `playlistQueue` has a next item, not already prefetched, and `duration - currentTime <= 120`, start the task; inside it also `_ = try? await asset.load(.isPlayable)` to warm the HLS master playlist. Call it from the periodic observer in `startProgressReporting()` (30 s interval; it also fires when playback starts, which covers short videos). Don't prefetch much earlier — the video file token can expire.
- `transitionToNextPlaylistItem`: if `nextItemPrefetch?.videoId == nextVideoId` and its value is non-nil, use it (build the `AVPlayerItem` from `prepared.asset`); otherwise call `preparePlaylistItem`. Reset `nextItemPrefetch = nil` either way.
- Cancel and clear the prefetch in `performDismissCleanup()`.
- If the compiler complains about `Sendable` for the task result, mark `PreparedPlaylistItem` `@unchecked Sendable` (it's only touched on the main actor).

## 3. History management

**API (confirmed):** remove one: `DELETE /api/v1/users/me/history/videos/{videoId}` — **numeric** id (`Video.id`, not the UUID). Clear all: `POST /api/v1/users/me/history/videos/remove` (optional JSON body `beforeDate`; send `{}`), returns 204.

- `Endpoint.swift`: `removeHistoryVideo(videoId: Int)` (DELETE) and `clearHistory` (POST, body `{}`); add both to `requiresAuth`, `method`, `path`, `httpBody`.
- `HistoryViewModel`: `remove(_ video: Video)` (optimistic removal, restore on failure; skip if `video.id == nil`) and `clearAll()` (clear list, reset paging).
- `HistoryView.swift`: not yet read. Check how long-press is already used on tiles (other grids use it to open detail). Options: a `.contextMenu` with "Remove from History", or a remove action on the detail screen. Add a "Clear History" button in the header with a `confirmationDialog`.
- Anonymous mode: `AnonymousHistoryStore` / `AnonymousHistoryViewModel` (not yet read) should get the same two actions for parity.

## 4. Background downloads (riskiest)

`DownloadManager` uses `URLSessionConfiguration.default`, so downloads stop when the app is suspended.
- Switch the download session to `URLSessionConfiguration.background(withIdentifier: "com.peernext.PeerTV.downloads")` (available on tvOS). Only download tasks are allowed on it — confirm every task created on `urlSession` is a download task. The HLS fallback via `AVAssetExportSession` cannot run in the background; leave it foreground-only.
- **Task state is in memory** (`taskVideoIdMap`, `taskMetaMap`, `speedTrackers`, keyed by `taskIdentifier`). If tvOS terminates the app while a download continues, `didFinishDownloadingTo` arrives after relaunch with no metadata and the file is lost. Persist the persistable part of `PendingDownloadMeta` (and the account id) as JSON in `task.taskDescription`; on init, call `urlSession.getAllTasks` and rebuild the maps and `activeDownloads`. `apiClient`/`accessToken` can't be persisted — after a relaunch, skip caption sidecars and the 401/403 HLS fallback.
- **`setActiveAccount(_:)` calls `cancelAllDownloadActivity()`**, and `SessionStore.init` calls it at every launch. With a background session, that cancels downloads that kept running. Only cancel when the account actually changes; route relaunched tasks to the account stored in their `taskDescription`.
- `didFinishDownloadingTo` must move the file before returning (the temp file is deleted afterward) — check the current implementation does that synchronously, not inside `DispatchQueue.main.async`.
- Add a `UIApplicationDelegate` via `@UIApplicationDelegateAdaptor` in `PeerTVApp.swift` implementing `application(_:handleEventsForBackgroundURLSession:completionHandler:)`; store the handler and call it from `urlSessionDidFinishEvents(forBackgroundURLSession:)`. Check that this delegate method is available on tvOS in the SDK before relying on it.
- tvOS can purge `Caches` (where downloads live) at any time; existing pruning handles missing files.

---

## Optional fixes (reviewed, not yet chosen by the user)

- **B. Shared token refresh.** `PeerTubeAPIClient.performAuthorizedDataRequest` refreshes separately for every request that gets a 401. PeerTube rotates refresh tokens, so concurrent 401s (typical on launch after an idle night) race; if `SessionStore.loadUsername` loses, `refreshAndRetry()` can read the already-used token and call `invalidateSession()`, signing the user out. Fix: one in-flight refresh per account (an actor holding a `Task`), shared by all callers and by `refreshAndRetry()`. Also skip the refresh when the request carried no token.
- **D. Resume positions saved only on close.** `PlayerCoordinator.savePlaybackPosition()` runs only on dismiss/skip-next, so a suspended-then-terminated app, crash, or power loss loses the local position (anonymous and fediverse playback have no server copy). Fix: also call it from `reportCurrentTime()` (30 s) and on `UIApplication.willResignActiveNotification`.
- **Audio session.** `PeerTVApp.init` activates the `.playback` session at launch, which stops other apps' audio when PeerTV opens. Activate it when the player is presented instead (Picture in Picture still needs it active during playback).
- **Watch reports without a token.** `reportCurrentTime()` sends `PUT /watching` every 30 s even for anonymous/fediverse clients with no token — a guaranteed 401. Skip when there's no access token.

## Known bug (not fixed)

`TransportBarController.detach()` sets `storyboardProvider = nil`, and quality switches (`performAssetSwap`) call `detach()`, so storyboard scrub thumbnails disappear after changing quality. Removing that line should be enough: `transitionToNextPlaylistItem` already clears the provider explicitly, and `tearDown()` discards the controller.

## Verification (needs a device or simulator)

- Search "This instance" as a non-admin account returns results; channel pages load for your own channel.
- Change sort/category repeatedly while the home grid is loading — the title and results always match.
- Start a download and scroll a grid — no hitching; tiles show the downloaded icon when it finishes.
- Control Center shows the title, channel, and artwork while a video plays, including after a quality switch and playlist autoplay.
- Pick 1.5x in the Speed menu, close, open another video — it starts at 1.5x with a pill; pause/play keeps 1.5x.
- For the new items: chapter markers + menu seek; playlist autoplay transitions faster; history remove/clear; a download continues after pressing the TV button and survives a relaunch.
