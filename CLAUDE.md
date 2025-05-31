# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

polarisOne is an iOS ARKit application that serves as an intelligent AR photography assistant. It uses real-time body tracking, 3D scene understanding, and Google's Gemini AI to help users capture better photos through live guidance and composition analysis.

## Development Commands

### Building and Running
- Open `polarisOne.xcodeproj` in Xcode
- Build: `Cmd+B` in Xcode
- Run on device: `Cmd+R` (requires physical iOS device with A12 chip or newer)
- Clean build: `Cmd+Shift+K`

### Testing
- Run unit tests: `Cmd+U` in Xcode or select the `polarisOneTests` scheme
- Unit tests use Swift Testing framework (not XCTest)
- Test files: `polarisOneTests/polarisOneTests.swift`

### Environment Setup
1. Set the `GEMINI_API_KEY` environment variable:
   - In Xcode: Edit Scheme → Run → Arguments → Environment Variables
   - Or create a `.env` file in the project root with: `GEMINI_API_KEY=your_api_key_here`

## Architecture

### Current Structure
The app is currently implemented in a single file (`polarisOne/ARKitCameraApp.swift`) but is architecturally organized as:
- **MVVM Pattern**: ObservableObject ViewModels manage state
- **ARViewModel**: Central coordinator for ARKit session, tracking, and measurements
- **APIService**: Handles Gemini API integration
- **ARViewContainer**: UIViewRepresentable bridge for ARView
- **Multiple specialized views**: ContentView, AnalysisOverlay, ControlPalette, etc.

### Key Components
1. **AR Session Management**: ARBodyTrackingConfiguration for human detection
2. **Height Calibration System**: Custom floor detection with anomaly handling
3. **3D Mesh Export**: Converts ARMeshAnchor to USDZ format (LiDAR devices)
4. **Reference Photo System**: Persistent storage for composition comparison
5. **Real-time Metrics**: Distance, height, orientation, lighting conditions

### API Integration
- Uses Google Gemini Flash 2.0 for scene analysis
- Endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent`
- Requires API key via environment variable

## Important Implementation Details

### ARKit Configuration
- Requires iOS 18.4+ deployment target
- Uses ARBodyTrackingConfiguration (requires A12+ chip)
- Plane detection enabled for floor calibration
- Scene reconstruction available on LiDAR devices

### Key Calculations
- Distance measurements use hip joint positions when available
- Height calculations relative to calibrated floor plane
- Body part visibility detection using joint tracking confidence
- FOV calculations based on camera intrinsics

### State Management
- `@Published` properties in ARViewModel for reactive UI updates
- UserDefaults for persistent storage (reference images, API responses)
- Combine framework for state synchronization

## Common Development Tasks

### Adding New AR Features
1. Extend ARViewModel with new tracking logic
2. Update ARSessionDelegate methods as needed
3. Add UI controls in ControlPalette view

### Modifying AI Analysis
1. Update APIService prompts in `analyzeScene()` or `compareWithReference()`
2. Adjust APIResponse model if changing response format
3. Update AnalysisOverlay view for new response fields

### Working with 3D Meshes
- ARMeshExporter class handles USDZ conversion
- Requires LiDAR-capable device for mesh capture
- Export logic in `exportSceneAsUSDZ()` method