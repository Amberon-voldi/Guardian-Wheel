# Guardian-Wheel

Guardian-Wheel is a lightweight, offline-first safety companion app for India’s gig delivery riders.
It focuses on real-time hazard and fatigue detection, peer-to-peer emergency alerts, and
crowdsourced road risk mapping that works even in low-signal peri-urban areas.

## Problem Statement

India’s gig delivery riders experience significantly higher accident rates due to poor road
conditions, low visibility, and fatigue—especially in low-signal peri-urban areas where
traditional SOS apps fail.

**Goal:** Build a lightweight, offline-first mesh-networked SOS mobile application that uses
phone sensors (GPS, accelerometer) to detect hazards and fatigue in real time.

The system should:

- Use device sensors (GPS, accelerometer, etc.) to detect crashes, harsh braking, and fatigue.
- Work in low-signal / no-signal environments by prioritizing offline-first behavior.
- Enable peer-to-peer Wi‑Fi Direct alert sharing within a 1 km radius.
- Auto-escalate emergencies to family or authorities with breadcrumb location tracking when
	connectivity is available.
- Crowdsource hazard data (potholes, bad lighting, accident hotspots) to improve safety for
	the entire delivery ecosystem.

## Key Features (Planned)

- **Real-time hazard detection** using phone motion sensors and GPS.
- **Fatigue monitoring** based on ride duration, movement patterns, and optional rider input.
- **Offline-first mesh alerts** via Wi‑Fi Direct within ~1 km radius.
- **SOS workflow** with auto-trigger on detected crash or manual trigger by rider.
- **Auto-escalation** to trusted contacts / authorities once network becomes available.
- **Breadcrumb location trail** for incident replay and assistance routing.
- **Crowdsourced hazard mapping** so riders can both receive and contribute safety data.

## Tech Stack

- **Framework:** Flutter (Dart)
- **Targets:** Android (primary), iOS; support for web/desktop mainly for debugging and admin views.
- **Connectivity:** Wi‑Fi Direct–based mesh (with cloud
	sync when online.

## Project Structure (High Level)

- lib/
	- main.dart – Flutter app entry point
- android/, ios/, macos/, linux/, windows/, web/ – platform-specific Flutter scaffolding
- test/ – basic widget and unit tests

## Development Setup

1. Install Flutter (see official docs: https://docs.flutter.dev/get-started/install).
2. Clone the repository:
	 - `git clone https://github.com/Amberon-voldi/Guardian-Wheel.git`
	 - `cd Guardian-Wheel` (or your local folder name)
3. Fetch dependencies:
	 - `flutter pub get`
4. Run the app on a connected device or emulator:
	 - `flutter run`

## Roadmap (Draft)

- [ ] Baseline Flutter UI for rider home screen and SOS flow.
- [ ] Sensor integration (GPS + accelerometer) and basic crash / harsh event detection.
- [ ] Local-only SOS flow with manual trigger and incident logging.
- [ ] Mesh networking prototype (Wi‑Fi Direct) for peer-to-peer alerts.
- [ ] Auto-escalation pipeline to family / authorities with breadcrumb trail.
- [ ] Hazard crowdsourcing UX and visualization for high-risk zones.

## License

TBD – add a license once finalized for the project.
