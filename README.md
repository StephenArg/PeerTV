<img width="422" height="300" alt="Screenshot 2026-03-05 at 11 30 05 PM" src="https://github.com/user-attachments/assets/69353f5f-c4dc-418e-b5cd-c39c3833e438" />

# PeerTV

A tvOS client for user-selected PeerTube instances, built with SwiftUI and async/await.

## Requirements

- Xcode 15.4+ (Swift 5.9+)
- tvOS 17.0 deployment target
- tvOS Simulator runtime (download from **Xcode → Settings → Platforms** if not installed)

## Build & Run

1. Open `PeerTV.xcodeproj` in Xcode.
2. Select the **PeerTV** scheme and an **Apple TV** simulator.
3. Press **⌘R** to build and run.

No third-party dependencies — the project uses only Apple frameworks (SwiftUI, AVKit, Security).

## Architecture

```
PeerTV/
├── App/                  # App entry (PeerTVApp), SessionStore, RootView
├── Models/               # Codable models (Video, VideoChannel, VideoPlaylist, RandomVideo, etc.)
├── Networking/           # PeerTubeAPIClient, Endpoint, OAuthService, TokenStore
├── Utilities/            # ImageCache, DebugFlags, ThumbnailURL helper
├── ViewModels/           # One ViewModel per screen/tab (Home, Search, Channels, etc.)
└── Views/
    ├── Debug/            # API Explorer, Raw JSON viewer
    ├── Detail/           # VideoDetail, ChannelDetail, PlaylistDetail
    ├── Onboarding/       # InstanceSetup, Login
    ├── Player/           # PlayerPresenter, PlayerCoordinator, PlayerView
    ├── Settings/         # Settings screen
    └── Tabs/             # MainTabView, VideoGrid, Search, Shuffle, ChannelsList, etc.
```

### Key patterns

- **MVVM** with `@StateObject` ViewModels and `@EnvironmentObject` for shared session state.
- **Thread-safe API client** (`PeerTubeAPIClient`) with `@MainActor`-isolated base URL.
- **Keychain token storage** via `TokenStore` — no plaintext token persistence.
- **OAuth 2.0 password flow** with automatic token refresh on 401 responses.
- **Generic `PaginatedResponse<T>`** for all list endpoints.
- **Resilient Codable models** — most fields are optional to tolerate API variance.
- **Lightweight `NSCache`-backed image cache** for thumbnail loading.
- **UIKit player presentation** via `PlayerPresenter` singleton — presents `AVPlayerViewController` directly (no SwiftUI `fullScreenCover` layer) for clean single-press Menu button dismissal on real hardware.
- **HLS-first resolution switching** — uses per-resolution `.m3u8` playlists for instant seek, with snapshot overlay during transitions.

## User Journeys

### 1. Instance Setup
On first launch, enter a PeerTube instance URL. The app validates it by calling `GET /api/v1/config`.

### 2. Login
Username/password login via OAuth 2.0 password grant. Tokens are stored in Keychain.

### 3. Browse
- **Home** — Trending videos with infinite scroll, search button at top
- **Shuffle** — (Optional and requires special peertube plugin) Random videos from the `random-video-tab` plugin (toggleable in Developer settings, requires app restart)
- **Subscriptions** — Your subscription feed + channel icons that link to channel detail (requires auth)
- **History** — Watch history, automatically tracked via the PeerTube API (requires auth)
- **Playlists** — All playlists including private ones like "Watch Later" (requires auth)
- **Channels** — Browse channels, view channel detail with videos, playlists, and subscribe/unsubscribe
- **Settings** — Change instance, log out, Developer settings, API Explorer

### 4. Search
Tap the **Search** button on the Home tab to open a dedicated search screen. The native tvOS keyboard appears when you focus the text field. Results are displayed as the same video grid with infinite scroll.

### 5. Playback
- **Single click** a video tile → plays directly in full-screen AVPlayerViewController
- **Long press** a video tile → navigates to VideoDetailView with metadata, like/dislike, and add-to-playlist controls
- **VideoDetailView** → Play button also opens the player
- Prefers HLS streaming playlists (per-resolution `.m3u8`); falls back to direct file URLs
- Resolution and speed controls in the player transport bar
- Watch progress is reported to the PeerTube instance for history tracking

## API Endpoints Used

| Endpoint | Purpose |
|----------|---------|
| `GET /api/v1/config` | Validate instance |
| `GET /api/v1/oauth-clients/local` | Get OAuth client credentials |
| `POST /api/v1/users/token` | Login / refresh token |
| `GET /api/v1/users/me` | Current user info |
| `GET /api/v1/videos` | List videos (trending/hot) |
| `GET /api/v1/videos/{id}` | Video detail + streaming URLs |
| `GET /api/v1/video-channels` | List channels |
| `GET /api/v1/video-channels/{handle}` | Channel detail |
| `GET /api/v1/video-channels/{handle}/videos` | Channel videos |
| `GET /api/v1/video-channels/{handle}/video-playlists` | Channel playlists |
| `GET /api/v1/users/me/subscriptions` | My subscriptions |
| `GET /api/v1/users/me/subscriptions/videos` | Subscription feed |
| `GET /api/v1/users/me/history/videos` | Watch history |
| `GET /api/v1/video-playlists` | Browse playlists |
| `GET /api/v1/accounts/{name}/video-playlists` | Account playlists |
| `GET /api/v1/video-playlists/{id}` | Playlist detail |
| `GET /api/v1/video-playlists/{id}/videos` | Playlist videos |
| `PUT /api/v1/videos/{id}/rate` | Like / dislike a video |
| `GET /api/v1/users/me/videos/{id}/rating` | Current user rating for a video |
| `POST /api/v1/video-playlists/{id}/videos` | Add video to playlist |
| `GET /api/v1/users/me/subscriptions/exist` | Check subscription status |
| `POST /api/v1/users/me/subscriptions` | Subscribe to a channel |
| `DELETE /api/v1/users/me/subscriptions/{handle}` | Unsubscribe from a channel |
| `PUT /api/v1/videos/{id}/watching` | Report watch progress (history) |
| `GET /api/v1/search/videos` | Search videos (with privacy filters) |
| `GET /plugins/random-video-tab/router/videos/random` | Random videos (plugin) |

## Debug / API Explorer

Set `DebugFlags.showAPIExplorer = true` (default) in `Utilities/DebugFlags.swift` to enable:
- **API Explorer** in Settings → fetch raw JSON for any endpoint
- **Show Raw JSON** button on VideoDetailView

This helps iterate on model fields without guessing the API response shape.
