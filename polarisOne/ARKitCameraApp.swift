//
//  ARKitCameraApp.swift
//  polarisOne
/*
 ARKitCameraApp.swift – Self‑contained SwiftUI + RealityKit demo
 -----------------------------------------------------------------
 • Live plane & mesh visualisation
 • Body detection with distance calculation
 • One‑tap USDZ export via share‑sheet (LiDAR only)
 • Integrated call to Flash 2.0 Image Generation Model
 • Integrated call to Flash 2.0 Text Generation Model
 -----------------------------------------------------------------
 Xcode 15 / iOS 17. Run on a real device (A12 Bionic+).

 NOTE: This code can exist in a single file, but comments below
       suggest a possible multi-file organization structure.
*/

import SwiftUI
import UIKit // UIActivityViewController, UIImage
import ARKit // plane / body / mesh detection
import RealityKit // ARView, debug overlays
import ModelIO // USDZ export helpers
import Metal // For MTLVertexFormat
import MetalKit // MTKMeshBufferAllocator
import Foundation // URL, Date, FileManager
import simd // simd_float4x4
import Combine

// MARK: - Potential File: Extensions/URL+Identifiable.swift
// MARK: – Convenience so URL works with .sheet(item:)
extension URL: Identifiable { public var id: String { absoluteString } }

// MARK: - Potential File: ARKitCameraApp.swift
// MARK: – Main App Entry
@main
struct ARKitCameraApp: App {
  var body: some SwiftUI.Scene {
    WindowGroup { ContentView().ignoresSafeArea() }
  }
}

// MARK: - Potential File: ViewModels/ARViewModel.swift
// MARK: – ObservableObject bridging ARSession → SwiftUI
final class ARViewModel: ObservableObject {
  @Published var shareURL: URL?
  @Published var distanceToPerson: String = "Looking for subjects..."
  @Published var detectedSubjectCount: Int = 0

  @Published var cameraHeightRelativeToEyes: String = "Eyes: N/A"
  @Published var generalCameraHeight: String = "Cam Height: N/A"
  @Published var visibleBodyPartsInfo: String = "Visible Parts: N/A"
  @Published var bodyTrackingHint: String = ""
  @Published var isBodyTrackingActive: Bool = false

  @Published var isCapturing: Bool = false
  @Published var showResponses: Bool = false

  @Published var selectedReferenceImage: ReferenceImage? = nil
  @Published var generatedImage: UIImage?
  @Published var isGeneratingPhoto: Bool = false

  // --- Enhanced Calibration State ---
  @Published var isCalibratingHeight: Bool = false
  @Published var calibrationInstruction: String = "Tap 'Start Calibration' for better height accuracy."
  @Published var triggerFloorMeasurement: Bool = false

  var calibratedFloorY: Float? = nil
  var isCalibrated: Bool = false
  var heightMeasurements: [Float] = []
  let maxMeasurements = 5
  @Published var calibrationResetTrigger: Bool = false

  // --- Automatic Reset Failsafe ---
  @Published var automaticResetCooldownActive: Bool = false
  private var automaticResetTimer: Timer?

  func startHeightCalibration() {
    automaticResetTimer?.invalidate()
    automaticResetCooldownActive = false
    isCalibrated = false
    calibratedFloorY = nil
    isCalibratingHeight = true
    heightMeasurements.removeAll()
    calibrationInstruction = "Point camera at floor. Tap 'Measure Floor' \(maxMeasurements) times."
    bodyTrackingHint = ""
    generalCameraHeight = "Cam Height: Calibrating..."
  }

  func requestFloorMeasurement() {
    guard isCalibratingHeight else { return }
    calibrationInstruction = "Getting measurement... Hold steady."
    triggerFloorMeasurement = true
  }

  func processTakenFloorMeasurement(cameraY: Float) {
    guard isCalibratingHeight else { return }
    heightMeasurements.append(cameraY)
    let measurementsTaken = heightMeasurements.count
    if measurementsTaken < maxMeasurements {
      calibrationInstruction = "Measurement \(measurementsTaken)/\(maxMeasurements) taken. Tap 'Measure Floor' again."
    } else {
      calibratedFloorY = heightMeasurements.reduce(0, +) / Float(heightMeasurements.count)
      isCalibratingHeight = false
      isCalibrated = true
      calibrationInstruction = "Floor calibrated at Y: \(String(format: "%.2f", calibratedFloorY!))m. Height is now relative to this."
      bodyTrackingHint = "Calibration Complete!"
    }
  }

  func resetCalibration(triggeredAutomatically: Bool = false) {
    isCalibratingHeight = false
    heightMeasurements.removeAll()
    isCalibrated = false
    calibratedFloorY = nil
    if triggeredAutomatically {
        calibrationInstruction = "Height anomaly detected. Calibration reset. Please recalibrate floor."
        bodyTrackingHint = "AUTO-RESET: Height issue. Recalibrate floor."
        generalCameraHeight = "Cam Height: N/A (Auto-Reset)"
        automaticResetCooldownActive = true
        automaticResetTimer?.invalidate()
        automaticResetTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.automaticResetCooldownActive = false
            if !(self?.isCalibratingHeight ?? false) && !(self?.isCalibrated ?? false) {
                 self?.calibrationInstruction = "Tap 'Start Calibration' for better height accuracy."
            }
            print("Automatic reset cooldown finished.")
        }
    } else {
        automaticResetTimer?.invalidate()
        automaticResetCooldownActive = false
        calibrationInstruction = "Calibration Reset. Tap 'Start Calibration' for accuracy."
        bodyTrackingHint = "Calibration has been reset manually."
        generalCameraHeight = "Cam Height: N/A (Recalibrate)"
    }
    calibrationResetTrigger.toggle()
  }

  private func getFinalCameraHeightForPrompt() -> (stringValue: String, numericValue: Double?) {
      var cameraHeightStringValue: String = "N/A"
      var numericHeightValue: Double? = nil
      let fullHeightString = generalCameraHeight
      if fullHeightString.lowercased().contains("calibrating") || fullHeightString.lowercased().contains("auto-reset") {
          cameraHeightStringValue = "Calibrating/Resetting"
      } else if fullHeightString.lowercased().contains("n/a") {
          cameraHeightStringValue = "N/A"
      } else {
          let components = fullHeightString.components(separatedBy: .whitespaces)
          if components.count >= 3 {
              let heightPart = components[2]
              let numericString = heightPart.replacingOccurrences(of: "m", with: "")
              if let numValue = Double(numericString) {
                  cameraHeightStringValue = numericString
                  numericHeightValue = numValue
              }
          }
      }
      var finalPromptString = cameraHeightStringValue
      if let numHeight = numericHeightValue, numHeight < -0.05 {
          if generalCameraHeight.lowercased().contains("below calib. floor") || generalCameraHeight.lowercased().contains("low?") {
              finalPromptString = "\(cameraHeightStringValue)m (potentially low)"
          } else if numHeight < -0.19 && (generalCameraHeight.lowercased().contains("origin") || !isCalibrated) {
              finalPromptString = "approx. 0m (origin likely high or detection issue)"
          } else {
              finalPromptString = "\(cameraHeightStringValue)m"
          }
      } else if cameraHeightStringValue == "N/A" || cameraHeightStringValue == "Calibrating/Resetting" {
          finalPromptString = "unknown (AR not ready/calibrating/reset)"
      } else if numericHeightValue != nil {
           finalPromptString = "\(cameraHeightStringValue)m"
      }
      return (finalPromptString, numericHeightValue)
  }

  func captureAndAnalyze() {
    guard let arView = ARMeshExporter.arView else { return }
    isCapturing = true
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let currentARImage = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }

    let (finalCameraHeightForPrompt, _) = getFinalCameraHeightForPrompt()
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]

    let prompt =
    """
    Act like an expert ARKit scene analyst. I will provide a photo of the current AR scene (it will be sent as the first image, and also duplicated as the second image in the payload, please use the first one), and some measured values about the subject and camera. Please provide a concise analysis (≤80 words) of the scene, including any suggestions for improving the photo or AR experience. List any detected issues or tips for better results.\n\nScene metrics:\n- Subject distance: \(distanceStringValue) m\n- Camera height: \(finalCameraHeightForPrompt)\n- Height relative to eyes: \(cameraHeightRelativeToEyes)\n- Visible body parts: \(visibleBodyPartsInfo)\n- Detected subject count: \(detectedSubjectCount)\n
    """
    let currentMetrics: [String: String] = [
        "distance_to_person_meters": distanceStringValue,
        "camera_height_meters": finalCameraHeightForPrompt,
        "camera_height_raw_string": generalCameraHeight,
        "camera_height_relative_to_eyes": cameraHeightRelativeToEyes,
        "visible_body_parts": visibleBodyPartsInfo,
        "detected_subject_count": "\(detectedSubjectCount)"
    ]
    Task {
      do {
        let (directivesText, _) = try await APIService.shared.sendImageGenerationRequest(
          referenceImage: currentARImage,
          currentImage: currentARImage,
          prompt: prompt,
          additionalMetrics: currentMetrics
        )
        let apiResponse = APIResponse(response: "Scene Analysis:\n\(directivesText)")
        await MainActor.run {
          let viewModel = ResponsesViewModel()
          viewModel.saveResponse(apiResponse)
          isCapturing = false
          showResponses = true
        }
      } catch {
        print("Error sending scene analysis request: \(error)")
        await MainActor.run {
          isCapturing = false
          self.bodyTrackingHint = "Scene analysis failed: \(error.localizedDescription)"
        }
      }
    }
  }

  func generateImprovedPhoto() {
    guard let arView = ARMeshExporter.arView else {
      print("ARView not available for image generation.")
      self.bodyTrackingHint = "AR system not ready."
      return
    }
    guard let refImageContainer = selectedReferenceImage, let photo1 = refImageContainer.image else {
        print("Reference photo (Photo 1) is missing.")
        self.bodyTrackingHint = "Please select a reference photo first."
        return
    }

    isGeneratingPhoto = true

    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let photo2 = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }

    let (finalCameraHeightForPrompt, _) = getFinalCameraHeightForPrompt()
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]

    // **FIXED PART 1: Directly access metadata, no 'if let' needed here for metadata itself**
    let refMeta = refImageContainer.metadata // refImageContainer is already unwrapped
    
    let distCam = refMeta.distanceFromCamera.isEmpty ? "N/A" : "\(refMeta.distanceFromCamera)m"
    let camHeight = refMeta.cameraHeight.isEmpty ? "N/A" : "\(refMeta.cameraHeight)m"
    let belowEyeline = refMeta.distanceBelowEyeline.isEmpty ? "N/A" : "\(refMeta.distanceBelowEyeline)m (camera below subject's eyes)"
    
    let photo1Details = """
    - Subject distance from camera: \(distCam)
    - Camera height: \(camHeight)
    - Camera position relative to subject's eyeline: \(belowEyeline)
    """

    let photo2Details = """
    - Subject distance from camera: \(distanceStringValue.isEmpty ? "N/A" : "\(distanceStringValue)m")
    - Camera height: \(finalCameraHeightForPrompt)
    - Camera height relative to subject's eyes: \(cameraHeightRelativeToEyes)
    - Visible body parts: \(visibleBodyPartsInfo)
    - Detected subject count: \(detectedSubjectCount)
    """

    let prompt = """
    You are an expert photography assistant. Your goal is to help me adjust my iPhone camera position and angle to make the live camera view (Photo 2) look as close as possible to a reference image (Photo 1).

    I will provide two images:
    1. Photo 1: The reference image I want to emulate. (This will be the first image in the payload)
    2. Photo 2: The current live view from my iPhone camera. (This will be the second image in the payload)

    And I'll provide some technical details for both photos.

    Reference Photo Details (Photo 1):
    \(photo1Details)

    Current Scene Details (Photo 2):
    \(photo2Details)

    Based on these two images and their details, provide very concise and precise directives (MAX 80 words total for all directives) to adjust my iPhone (Photo 2) to better match Photo 1's perspective, angle, and subject framing.
    Output exactly six directives, one for each degree of freedom (DOF). If no change is needed for a DOF, state "no change" or "minimal change".
    Use numeric values in meters (m) for translations and degrees (°) for rotations. Be specific.

    Directives Format:
    • X (Left/Right): Move ___ m left/right (or 'no change').
    • Y (Up/Down): Move ___ m up/down (or 'no change').
    • Z (Forward/Back): Move ___ m forward/back (or 'no change').
    • Yaw (Pan Left/Right): Turn ___° left/right (or 'no change').
    • Pitch (Tilt Up/Down): Tilt ___° up/down (or 'no change').
    • Roll (Rotate CW/CCW): Roll ___° clockwise/counter-clockwise (or 'no change').

    Optional: If a significant overall angle change is needed (e.g., from frontal to profile), add a brief "Angle Tip:" after the six directives.
    Example response:
    X (Left/Right): Move 0.1m right.
    Y (Up/Down): Move 0.05m up.
    Z (Forward/Back): Move 0.2m back.
    Yaw (Pan Left/Right): Turn 5° left.
    Pitch (Tilt Up/Down): Tilt 2° down.
    Roll (Rotate CW/CCW): no change.
    """

    let currentMetrics: [String: String] = [
        "distance_to_person_meters": distanceStringValue,
        "camera_height_meters": finalCameraHeightForPrompt,
        "camera_height_raw_string": generalCameraHeight,
        "camera_height_relative_to_eyes": cameraHeightRelativeToEyes,
        "visible_body_parts": visibleBodyPartsInfo,
        "detected_subject_count": "\(detectedSubjectCount)"
    ]

    Task {
        do {
            let (directivesText, _) = try await APIService.shared.sendImageGenerationRequest(
                referenceImage: photo1,
                currentImage: photo2,
                prompt: prompt,
                additionalMetrics: currentMetrics
            )
            let apiResponse = APIResponse(response: "Photo Directives:\n\(directivesText)")
            await MainActor.run {
                let responsesVM = ResponsesViewModel()
                responsesVM.saveResponse(apiResponse)
                self.bodyTrackingHint = "Directives: \(directivesText.prefix(60))... (See Responses)"
                self.isGeneratingPhoto = false
                self.showResponses = true
            }
        } catch {
            print("Error sending image guidance request: \(error.localizedDescription)")
            await MainActor.run {
                self.isGeneratingPhoto = false
                self.bodyTrackingHint = "Guidance Gen failed: \(error.localizedDescription.prefix(50))..."
            }
        }
    }
  }
}

// MARK: - Potential File: Views/ContentView.swift
// MARK: – Root SwiftUI view
struct ContentView: View {
  @StateObject private var vm = ARViewModel()
  @StateObject private var refVM = ReferenceImageViewModel()
  @StateObject private var boxVM = BoxPlacementViewModel()

  var body: some View {
    ZStack(alignment: .topLeading) {
      ARViewContainer(viewModel: vm, boxVM: boxVM).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 8) {
        if let refContainer = vm.selectedReferenceImage, let img = refContainer.image {
          Button(action: { refVM.showSelector = true }) {
            Image(uiImage: img)
              .resizable().scaledToFit().frame(width: 120, height: 120)
              .cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2))
              .shadow(radius: 4)
          }.padding(.bottom, 8).accessibilityLabel("Reference Image. Tap to change.")
        } else {
          Button(action: { refVM.showSelector = true }) {
            VStack {
              Image(systemName: "photo.on.rectangle").resizable().scaledToFit().frame(width: 60, height: 60).foregroundColor(.gray)
              Text("Add Reference Image").font(.caption)
            }.frame(width: 120, height: 120).background(Color(.systemGray6)).cornerRadius(12)
             .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
          }.padding(.bottom, 8)
        }
        Button(action: { boxVM.showBoxInput = true }) {
            Label("Box Placement", systemImage: "cube").font(.caption).padding(6).background(Color(.systemGray6)).cornerRadius(8)
        }.padding(.bottom, 8)
        
        VStack(alignment: .leading, spacing: 5) {
            Button(action: { vm.resetCalibration(triggeredAutomatically: false) }) {
                Label("Reset Calibration", systemImage: "arrow.counterclockwise")
                    .font(.caption).padding(6).background(Color(.systemGray5)).cornerRadius(8)
            }
            Text(vm.calibrationInstruction)
                .font(.caption).lineLimit(nil).fixedSize(horizontal: false, vertical: true).padding(5)
                .background(
                    Group {
                        if vm.calibrationInstruction.lowercased().contains("anomaly") || vm.calibrationInstruction.lowercased().contains("auto-reset") { Color.orange.opacity(0.3) }
                        else if vm.isCalibratingHeight || (!vm.isCalibrated && !vm.calibrationInstruction.lowercased().contains("complete")) { Color.yellow.opacity(0.3) }
                        else if vm.calibrationInstruction.lowercased().contains("complete") || vm.calibrationInstruction.lowercased().contains("calibrated at") { Color.green.opacity(0.2) }
                        else { Color.clear }
                    }).cornerRadius(5)
            if vm.isCalibratingHeight {
                Button(action: { vm.requestFloorMeasurement() }) {
                    Label("Measure Floor (\(vm.heightMeasurements.count)/\(vm.maxMeasurements))", systemImage: "ruler.fill")
                }.font(.caption).padding(6).background(Color.blue.opacity(0.3)).cornerRadius(8)
                .disabled(vm.heightMeasurements.count >= vm.maxMeasurements)
            } else if !vm.isCalibrated || vm.automaticResetCooldownActive {
                Button(action: { vm.startHeightCalibration() }) {
                    Label("Start Floor Calibration", systemImage: "target")
                }.font(.caption).padding(6).background(Color.green.opacity(0.3)).cornerRadius(8)
            }
        }.padding(.bottom, 8)

        if !vm.bodyTrackingHint.isEmpty {
          Text(vm.bodyTrackingHint)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(.ultraThinMaterial).cornerRadius(8)
            .foregroundColor(
                vm.bodyTrackingHint.lowercased().contains("error") ||
                vm.bodyTrackingHint.lowercased().contains("failed") ||
                vm.bodyTrackingHint.lowercased().contains("auto-reset") ? .red : .primary
            ).font(.caption)
        }
        Text("Subjects: \(vm.detectedSubjectCount)").infoStyle()
        Text(vm.distanceToPerson).infoStyle()
        Text(vm.cameraHeightRelativeToEyes).infoStyle()
        Text(vm.generalCameraHeight).infoStyle()
        Text(vm.visibleBodyPartsInfo).infoStyle().lineLimit(3)
      }
      .padding()

      VStack {
        Spacer()
        if let generatedImg = vm.generatedImage {
            Image(uiImage: generatedImg)
                .resizable().scaledToFit().frame(width: 100, height: 100, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray, lineWidth: 1))
                .padding(.bottom, 5)
        }

        HStack(spacing: 15) {
          Spacer()
          Button(action: { vm.captureAndAnalyze() }) {
            Image(systemName: "wand.and.stars").font(.system(size: 22, weight: .semibold))
              .padding().background(.ultraThinMaterial, in: Circle()).accessibilityLabel("Analyze Scene (Gemini)")
          }
          .disabled(vm.isCapturing || vm.isGeneratingPhoto || vm.isCalibratingHeight)
          .opacity((vm.isCapturing || vm.isGeneratingPhoto || vm.isCalibratingHeight) ? 0.5 : 1.0)
           
          Button(action: {
            if vm.selectedReferenceImage == nil { vm.bodyTrackingHint = "Error: Set reference photo first."; return }
            if !vm.isCalibrated && !vm.generalCameraHeight.lowercased().contains("floor") && !vm.generalCameraHeight.lowercased().contains("plane") {
                vm.bodyTrackingHint = "Calibrate floor first for accurate photo guidance."
                return
            }
            vm.generateImprovedPhoto()
          }) {
            Image(systemName: "camera.filters").font(.system(size: 22, weight: .semibold))
              .padding().background(.ultraThinMaterial, in: Circle()).accessibilityLabel("Get Photo Guidance")
          }
          .disabled(vm.isCapturing || vm.isGeneratingPhoto || !vm.isBodyTrackingActive || vm.detectedSubjectCount == 0 || vm.selectedReferenceImage == nil || vm.isCalibratingHeight)
          .opacity((vm.isCapturing || vm.isGeneratingPhoto || !vm.isBodyTrackingActive || vm.detectedSubjectCount == 0 || vm.selectedReferenceImage == nil || vm.isCalibratingHeight) ? 0.5 : 1.0)
           
          Button(action: {
            if !vm.isBodyTrackingActive { vm.shareURL = ARMeshExporter.exportCurrentScene() }
          }) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .semibold))
              .padding().background(.ultraThinMaterial, in: Circle()).accessibilityLabel("Export Scene")
          }
          .disabled(vm.isBodyTrackingActive || !ARMeshExporter.hasMesh || vm.isCapturing || vm.isGeneratingPhoto || vm.isCalibratingHeight)
          .opacity((vm.isBodyTrackingActive || !ARMeshExporter.hasMesh || vm.isCapturing || vm.isGeneratingPhoto || vm.isCalibratingHeight) ? 0.5 : 1.0)
          Spacer()
        }
        .padding(.bottom, 10)
      }
      .padding(.horizontal)
    }
    .sheet(item: $vm.shareURL) { url in ActivityView(activityItems: [url]) }
    .sheet(isPresented: $vm.showResponses) { ResponsesView() }
    .sheet(isPresented: $refVM.showSelector) {
      ReferenceImageSelector(vm: refVM)
    }
    .sheet(isPresented: $boxVM.showBoxInput) {
      BoxPlacementPanel(vm: boxVM, onAdd: { _ in }, onDelete: { _ in })
    }
    .onChange(of: refVM.selected) { newValue in
        vm.selectedReferenceImage = newValue
        if newValue == nil && !vm.isGeneratingPhoto && !vm.isCapturing {
            vm.bodyTrackingHint = "Tip: Set a reference photo for image generation."
        }
    }
    .onAppear {
      if !ARBodyTrackingConfiguration.isSupported { vm.bodyTrackingHint = "ARBodyTracking not supported." }
      
      APIService.shared.configure(
        apiKey: "YOUR_ANALYSIS_API_KEY_IF_ANY",



      )
      
      let geminiAPIKey = EnvHelper.value(for: "GEMINI_API_KEY")
      let geminiBaseURLForFlashModel = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
      
      APIService.shared.configureFlash(
        apiKey: geminiAPIKey,
        apiURL: geminiBaseURLForFlashModel
      )
      
      vm.selectedReferenceImage = refVM.selected // Initialize on appear
      if vm.selectedReferenceImage == nil { vm.bodyTrackingHint = "Tip: Set a reference photo for image generation." }
    }
  }
}

struct InfoTextStyle: ViewModifier {
  func body(content: Content) -> some View {
    content.padding(.vertical, 5).padding(.horizontal, 10).background(.ultraThinMaterial).cornerRadius(8).font(.caption)
  }
}
extension View { func infoStyle() -> some View { self.modifier(InfoTextStyle()) } }

// MARK: - Potential File: Views/ARViewContainer.swift
struct ARViewContainer: UIViewRepresentable {
  @ObservedObject var viewModel: ARViewModel
  @ObservedObject var boxVM: BoxPlacementViewModel

  func makeUIView(context: Context) -> ARView {
    let view = ARView(frame: .zero)
    ARMeshExporter.arView = view
    context.coordinator.arView = view
    view.session.delegate = context.coordinator

    if ARBodyTrackingConfiguration.isSupported {
      let configuration = ARBodyTrackingConfiguration()
      configuration.automaticSkeletonScaleEstimationEnabled = true
      configuration.planeDetection = [.horizontal]
      view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
      DispatchQueue.main.async {
        self.viewModel.bodyTrackingHint = "Body Tracking Active"
        self.viewModel.isBodyTrackingActive = true
        ARMeshExporter.hasMesh = false
      }
      print("✅ ARBodyTrackingConfiguration enabled.")
    } else {
      DispatchQueue.main.async {
        self.viewModel.bodyTrackingHint = "ARBodyTracking Not Supported. Limited features."
        self.viewModel.isBodyTrackingActive = false
      }
      print("⚠️ ARBodyTrackingConfiguration not supported. Falling back to WorldTracking.")
      let configuration = ARWorldTrackingConfiguration()
      configuration.planeDetection = [.horizontal]
      configuration.sceneReconstruction = .mesh
      view.session.run(configuration)
      ARMeshExporter.hasMesh = true
    }
    let coach = ARCoachingOverlayView()
    coach.session = view.session
    coach.goal = .tracking
    coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    coach.frame = view.bounds
    view.addSubview(coach)
    return view
  }

  func updateUIView(_ uiView: ARView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(vm: viewModel, boxVM: boxVM)
  }

  final class Coordinator: NSObject, ARSessionDelegate {
    private var vm: ARViewModel
    private var boxVM: BoxPlacementViewModel
    weak var arView: ARView?
    private var currentBodyAnchor: ARBodyAnchor?
    private var cancellables: Set<AnyCancellable> = []
    private var boxAnchors: [UUID: AnchorEntity] = [:]
    private let autoResetThreshold: Float = -0.35
    private let autoResetThresholdUncalibratedFactor: Float = -0.15
     
    init(vm: ARViewModel, boxVM: BoxPlacementViewModel) {
      self.vm = vm
      self.boxVM = boxVM
      super.init()
      vm.$calibrationResetTrigger
        .sink { [weak self] _ in self?.resetCalibrationInternal() }
        .store(in: &cancellables)
      vm.$triggerFloorMeasurement
        .sink { [weak self] triggered in
          if triggered { self?.takeFloorMeasurementForCalibration() }
        }
        .store(in: &cancellables)
      boxVM.$boxes.sink { [weak self] boxes in self?.syncBoxes(boxes) }.store(in: &cancellables)
      print("Coordinator Initialized")
    }

    func takeFloorMeasurementForCalibration() {
      guard let cameraY = arView?.session.currentFrame?.camera.transform.translation.y else {
        DispatchQueue.main.async {
          self.vm.calibrationInstruction = "Error: Could not get camera position. Try again."
          self.vm.triggerFloorMeasurement = false
        }
        return
      }
      DispatchQueue.main.async {
        self.vm.processTakenFloorMeasurement(cameraY: cameraY)
        self.vm.triggerFloorMeasurement = false
      }
    }
      
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      calculateGeneralCameraHeight(cameraTransform: frame.camera.transform, frame: frame)
      guard let bodyAnchor = self.currentBodyAnchor, vm.isBodyTrackingActive else {
        if vm.detectedSubjectCount > 0 && vm.isBodyTrackingActive {
            DispatchQueue.main.async {
                self.vm.detectedSubjectCount = 0
                self.vm.distanceToPerson = "Looking for subjects..."
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
            }
        } else if !vm.isBodyTrackingActive {
            DispatchQueue.main.async {
                self.vm.distanceToPerson = "Body tracking N/A"
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
            }
        }
        return
      }
      let cameraTransform = frame.camera.transform
      let bodyTransform = bodyAnchor.transform
      let distance = simd_distance(cameraTransform.translation, bodyTransform.translation)
      let distanceString = String(format: "%.1f m", distance)
      calculateCameraHeightRelativeToEyes(bodyAnchor: bodyAnchor, cameraTransform: cameraTransform)
      determineVisibleBodyParts(bodyAnchor: bodyAnchor, frame: frame)
      DispatchQueue.main.async {
        if self.vm.distanceToPerson != distanceString { self.vm.distanceToPerson = distanceString }
      }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { processAnchors(anchors, session: session, event: "Added") }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { processAnchors(anchors, session: session, event: "Updated") }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
      var bodyAnchorRemoved = false
      if let currentId = self.currentBodyAnchor?.identifier, anchors.contains(where: { $0.identifier == currentId }) {
        self.currentBodyAnchor = nil; bodyAnchorRemoved = true
        print("Tracked body anchor \(currentId) removed.")
      }
      if let currentFrame = session.currentFrame {
         let bodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         DispatchQueue.main.async {
           if self.vm.detectedSubjectCount != bodyAnchorsInFrame.count { self.vm.detectedSubjectCount = bodyAnchorsInFrame.count }
           if bodyAnchorRemoved && bodyAnchorsInFrame.isEmpty {
                self.vm.distanceToPerson = "Looking for subjects..."; self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"; self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
           } else if bodyAnchorRemoved && !bodyAnchorsInFrame.isEmpty {
               self.currentBodyAnchor = bodyAnchorsInFrame.first
               print("Switched to new body anchor: \(self.currentBodyAnchor?.identifier.uuidString ?? "None") after removal.")
           }
         }
      }
    }

    private func processAnchors(_ anchors: [ARAnchor], session: ARSession, event: String) {
      for anchor in anchors where anchor is ARMeshAnchor {
          print("----> Found MESH ANCHOR on \(event)")
          DispatchQueue.main.async { ARMeshExporter.hasMesh = true }
      }
      let bodyAnchors = anchors.compactMap { $0 as? ARBodyAnchor }
      if !bodyAnchors.isEmpty {
        print("----> Found \(bodyAnchors.count) BODY ANCHOR(s) on \(event)!")
        if self.currentBodyAnchor == nil || !anchors.contains(where: { $0.identifier == self.currentBodyAnchor!.identifier }) {
          self.currentBodyAnchor = bodyAnchors.first
           print("----> Now Tracking body anchor: \(self.currentBodyAnchor!.identifier)")
        }
      }
      if let currentFrame = session.currentFrame {
         let allBodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         DispatchQueue.main.async {
          if self.vm.detectedSubjectCount != allBodyAnchorsInFrame.count {
            self.vm.detectedSubjectCount = allBodyAnchorsInFrame.count
            print("----> Updated Subject Count: \(allBodyAnchorsInFrame.count)")
          }
          if allBodyAnchorsInFrame.isEmpty && self.currentBodyAnchor != nil {
              self.currentBodyAnchor = nil
              print("----> No body anchors in frame. Cleared currentBodyAnchor.")
          }
         }
      }
    }

    func calculateCameraHeightRelativeToEyes(bodyAnchor: ARBodyAnchor, cameraTransform: matrix_float4x4) {
      guard let headJointTransform = bodyAnchor.skeleton.modelTransform(for: .head) else {
        DispatchQueue.main.async { self.vm.cameraHeightRelativeToEyes = "Eyes: Head Joint N/A" }
        return
      }
      let jointWorldTransform = bodyAnchor.transform * headJointTransform
      let jointWorldPosition = jointWorldTransform.translation
      let cameraWorldPosition = cameraTransform.translation
      let estimatedEyeYOffset: Float = -0.1
      let estimatedEyeWorldY = jointWorldPosition.y + estimatedEyeYOffset
      let heightDifference = cameraWorldPosition.y - estimatedEyeWorldY
      let directionText = heightDifference > 0.05 ? "Above" : (heightDifference < -0.05 ? "Below" : "Level with")
      let text = String(format: "Eyes: Cam %.2fm %@ Subject", abs(heightDifference), directionText)
      DispatchQueue.main.async {
        if self.vm.cameraHeightRelativeToEyes != text { self.vm.cameraHeightRelativeToEyes = text }
      }
    }

    func calculateGeneralCameraHeight(cameraTransform: matrix_float4x4, frame: ARFrame) {
        let cameraWorldY = cameraTransform.translation.y
        var text: String
        if !vm.isCalibratingHeight && !vm.automaticResetCooldownActive {
            var triggerAutoReset = false
            var reasonForReset = ""
            if vm.isCalibrated, let calibFloorY = vm.calibratedFloorY {
                let heightRelativeToCalibrated = cameraWorldY - calibFloorY
                if heightRelativeToCalibrated < self.autoResetThreshold {
                    triggerAutoReset = true
                    reasonForReset = "Height (\(String(format: "%.2f", heightRelativeToCalibrated))m) sig. below calibrated floor."
                }
            } else {
                let floorPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
                                    .filter { $0.alignment == .horizontal && ($0.classification == .floor || $0.classification == .table) }
                if let floorPlane = floorPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
                    let heightRelativeToDetectedFloor = cameraWorldY - floorPlane.transform.translation.y
                    if heightRelativeToDetectedFloor < (self.autoResetThreshold - 0.15) {
                        triggerAutoReset = true
                        reasonForReset = "Height (\(String(format: "%.2f", heightRelativeToDetectedFloor))m) sig. below ARKit floor/table."
                    }
                }
            }
            if triggerAutoReset {
                print("!!! AUTO CALIBRATION RESET: \(reasonForReset) !!!")
                DispatchQueue.main.async { self.vm.resetCalibration(triggeredAutomatically: true) }
                return
            }
        }
        if vm.isCalibratingHeight { text = "Cam Height: Calibrating..." }
        else if vm.isCalibrated, let calibratedFloorY = vm.calibratedFloorY {
            let height = cameraWorldY - calibratedFloorY
            if height < -0.01 && height >= autoResetThreshold { text = String(format: "Cam Height: %.2fm (Below Calib. Floor)", height) }
            else { text = String(format: "Cam Height: %.2fm (Calibrated)", height) }
        } else {
            if vm.automaticResetCooldownActive { text = "Cam Height: N/A (Auto-Reset)" }
            else {
                let floorPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal && ($0.classification == .floor || $0.classification == .table)}
                if let floorPlane = floorPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
                    let height = cameraWorldY - floorPlane.transform.translation.y
                    if height < -0.1 && height >= (autoResetThreshold - 0.15) { text = String(format: "Cam Height: %.2fm (Floor/Table - Low?)", height) }
                    else { text = String(format: "Cam Height: %.2fm (\(floorPlane.classification == .floor ? "Floor" : "Table"))", height) }
                } else {
                    let horizontalPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
                    if let anyHorizontalPlane = horizontalPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
                        let height = cameraWorldY - anyHorizontalPlane.transform.translation.y
                         if height < -0.1 { text = String(format: "Cam Height: %.2fm (Plane - Low?)", height) }
                         else { text = String(format: "Cam Height: %.2fm (Plane)", height) }
                    } else { text = String(format: "Cam Height: %.2fm (Origin)", cameraWorldY) }
                }
            }
        }
        DispatchQueue.main.async {
            if !self.vm.automaticResetCooldownActive || text != "Cam Height: N/A (Auto-Reset)" {
                if self.vm.generalCameraHeight != text { self.vm.generalCameraHeight = text }
            }
        }
    }

    func determineVisibleBodyParts(bodyAnchor: ARBodyAnchor, frame: ARFrame) {
      guard let arView = self.arView else { DispatchQueue.main.async { self.vm.visibleBodyPartsInfo = "Visible Parts: ARView N/A" }; return }
      var visibleJointsDescriptions: [String] = []
      // **FIXED PART 2: Changed .hip to .root**
      let jointsOfInterest: [ARKit.ARSkeleton.JointName] = [.head, .leftShoulder, .leftHand, .rightShoulder, .rightHand, .leftFoot, .rightFoot, .root]
      for jointName in jointsOfInterest {
        guard let jointModelTransform = bodyAnchor.skeleton.modelTransform(for: jointName) else { continue }
        let jointWorldPosition = (bodyAnchor.transform * jointModelTransform).translation
        if let screenPoint = arView.project(jointWorldPosition) {
          let pointInCameraSpace = frame.camera.transform.inverse * SIMD4<Float>(jointWorldPosition.x, jointWorldPosition.y, jointWorldPosition.z, 1.0)
          if pointInCameraSpace.z < 0 &&
             screenPoint.x >= arView.bounds.minX && screenPoint.x <= arView.bounds.maxX &&
             screenPoint.y >= arView.bounds.minY && screenPoint.y <= arView.bounds.maxY {
            visibleJointsDescriptions.append(jointName.rawValue.replacingOccurrences(of: "_joint", with: "").replacingOccurrences(of: "_", with: " ").capitalizedFirst())
          }
        }
      }
      let text = !visibleJointsDescriptions.isEmpty ? "Visible: " + visibleJointsDescriptions.prefix(5).joined(separator: ", ") + (visibleJointsDescriptions.count > 5 ? "..." : "") : (vm.detectedSubjectCount > 0 ? "Visible Parts: Subject Occluded/Out of View" : "Visible Parts: N/A")
      DispatchQueue.main.async {
        if self.vm.visibleBodyPartsInfo != text { self.vm.visibleBodyPartsInfo = text }
      }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
      print("❌ AR Session Failed: \(error.localizedDescription)")
      DispatchQueue.main.async { self.vm.bodyTrackingHint = "AR Session Failed: \(error.localizedDescription.prefix(50))" }
    }
    func sessionWasInterrupted(_ session: ARSession) {
      print("⏸️ AR Session Interrupted")
      DispatchQueue.main.async { self.vm.bodyTrackingHint = "AR Session Interrupted. Trying to resume..." }
    }
    func sessionInterruptionEnded(_ session: ARSession) {
      print("▶️ AR Session Interruption Ended. Resetting session.")
      if let configuration = session.configuration {
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.async {
          self.vm.bodyTrackingHint = self.vm.isBodyTrackingActive ? "Body Tracking Active" : "World Tracking Active"
          self.vm.distanceToPerson = "Looking for subjects..."
          self.vm.resetCalibration(triggeredAutomatically: false)
        }
      } else { DispatchQueue.main.async { self.vm.bodyTrackingHint = "Session resumed, but config lost." } }
    }
    private func resetCalibrationInternal() { print("Coordinator: Observed calibration reset trigger.") }
    private func syncBoxes(_ boxes: [PlacedBox]) { /* ... (Existing box syncing logic) ... */ }
  }
}

// MARK: - Potential File: Extensions/String+Helpers.swift
extension String { func capitalizedFirst() -> String { prefix(1).capitalized + dropFirst() } }

// MARK: - Potential File: Utilities/ARMeshExporter.swift
struct ARMeshExporter {
  static weak var arView: ARView?
  static var hasMesh = false
  static func exportCurrentScene() -> URL? {
    guard let view = arView, hasMesh, let anchors = view.session.currentFrame?.anchors else {
      print("Export failed: ARView not set, no mesh, or no current anchors."); return nil
    }
    let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
    guard !meshAnchors.isEmpty else { print("Export failed: No ARMeshAnchors found."); return nil }
    print("Exporting \(meshAnchors.count) mesh anchors...")
    let asset = MDLAsset(); guard let device = MTLCreateSystemDefaultDevice() else { print("Export failed: No Metal device."); return nil }
    let allocator = MTKMeshBufferAllocator(device: device)
    meshAnchors.forEach { asset.add(MDLMesh(arMeshAnchor: $0, allocator: allocator)) }
    guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { print("Export failed: No docs dir."); return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fileName = "Scan_\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).usdz"
    let fileURL = docsDir.appendingPathComponent(fileName)
    print("Attempting to export to: \(fileURL.path)")
    do { try asset.export(to: fileURL); print("✅ Export successful!"); return fileURL }
    catch { print("❌ Export error: \(error.localizedDescription)"); return nil }
  }
}

// MARK: - Potential File: Extensions/Metal+MDLVertexFormat.swift
extension MTLVertexFormat {
    func toMDLVertexFormat() -> MDLVertexFormat {
        switch self {
        case .float: return .float; case .float2: return .float2; case .float3: return .float3; case .float4: return .float4
        case .half: return .half; case .half2: return .half2; case .half3: return .half3; case .half4: return .half4
        case .char: return .char; case .char2: return .char2; case .char3: return .char3; case .char4: return .char4
        case .short: return .short; case .short2: return .short2; case .short3: return .short3; case .short4: return .short4
        case .int: return .int; case .int2: return .int2; case .int3: return .int3; case .int4: return .int4
        case .uchar: return .uChar; case .uchar2: return .uChar2; case .uchar3: return .uChar3; case .uchar4: return .uChar4
        case .ushort: return .uShort; case .ushort2: return .uShort2; case .ushort3: return .uShort3; case .ushort4: return .uShort4
        case .uint: return .uInt; case .uint2: return .uInt2; case .uint3: return .uInt3; case .uint4: return .uInt4
        default: print("⚠️ Unhandled MTLVertexFormat \(self.rawValue)"); return .invalid
        }
    }
}

// MARK: - Potential File: Extensions/MDLMesh+ARMeshAnchor.swift
extension MDLMesh {
  convenience init(arMeshAnchor a: ARMeshAnchor, allocator: MTKMeshBufferAllocator) {
    let g = a.geometry
    let vData = Data(bytesNoCopy: g.vertices.buffer.contents(), count: g.vertices.stride * g.vertices.count, deallocator: .none)
    let fData = Data(bytesNoCopy: g.faces.buffer.contents(), count: g.faces.bytesPerIndex * g.faces.count * g.faces.indexCountPerPrimitive, deallocator: .none)
    let vBuf = allocator.newBuffer(with: vData, type: .vertex); let iBuf = allocator.newBuffer(with: fData, type: .index)
    let sub = MDLSubmesh(indexBuffer: iBuf, indexCount: g.faces.count * g.faces.indexCountPerPrimitive, indexType: .uInt32, geometryType: .triangles, material: nil)
    let desc = Self.vertexDescriptor(from: g.vertices, normals: g.normals, textureCoordinates: nil)
    self.init(vertexBuffer: vBuf, vertexCount: g.vertices.count, descriptor: desc, submeshes: [sub])
    self.transform = MDLTransform(matrix: a.transform)
  }
  static func vertexDescriptor(from vertices: ARGeometrySource, normals: ARGeometrySource?, textureCoordinates: ARGeometrySource?) -> MDLVertexDescriptor {
    let desc = MDLVertexDescriptor(); var attrIdx = 0; var bufIdx = 0
    desc.attributes[attrIdx] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: vertices.format.toMDLVertexFormat(), offset: 0, bufferIndex: bufIdx)
    desc.layouts[bufIdx] = MDLVertexBufferLayout(stride: vertices.stride); attrIdx += 1; bufIdx += 1
    if let norm = normals {
        desc.attributes[attrIdx] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: norm.format.toMDLVertexFormat(), offset: 0, bufferIndex: bufIdx)
        desc.layouts[bufIdx] = MDLVertexBufferLayout(stride: norm.stride); attrIdx += 1; bufIdx += 1
    }
    if let tex = textureCoordinates {
        desc.attributes[attrIdx] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: tex.format.toMDLVertexFormat(), offset: 0, bufferIndex: bufIdx)
        desc.layouts[bufIdx] = MDLVertexBufferLayout(stride: tex.stride)
    }
    return desc
  }
}

// MARK: - Potential File: Views/ActivityView.swift
struct ActivityView: UIViewControllerRepresentable {
  let activityItems: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
  func updateUIViewController(_ uiVC: UIActivityViewController, context: Context) {}
}

// MARK: - Potential File: Extensions/SIMD+Helpers.swift
extension simd_float4x4 { var translation: simd_float3 { simd_float3(columns.3.x, columns.3.y, columns.3.z) } }
extension SIMD3 where Scalar == Float { static var zero: SIMD3<Float> { .init(0,0,0) } }

// MARK: - Potential File: Models/APIResponse.swift
struct APIResponse: Identifiable, Codable {
  let id: UUID; let timestamp: Date; let response: String
  init(response: String) { self.id = UUID(); self.timestamp = Date(); self.response = response }
}

// MARK: - Potential File: Services/APIService.swift
class APIService {
  static let shared = APIService()
  private var analysisApiKey: String = ""
  private var analysisApiURL: String = ""
  
  private var flashApiKey: String = ""
  private var flashApiURLString: String = ""

  func configure(apiKey: String, apiURL: String) {
    self.analysisApiKey = apiKey
    self.analysisApiURL = apiURL
    print("APIService (Analysis) configured. URL: \(apiURL.isEmpty ? "Not Set" : apiURL), Key: \(apiKey.isEmpty ? "Not Set" : "Set")")
  }
   
  func configureFlash(apiKey: String, apiURL: String) {
    self.flashApiKey = apiKey
    if apiKey.isEmpty {
        self.flashApiURLString = apiURL
         print("APIService (Flash Gen) configured. API Key IS EMPTY. URL: \(apiURL)")
    } else if apiURL.contains("?key=") || apiURL.contains("&key=") {
        self.flashApiURLString = apiURL
        print("APIService (Flash Gen) configured. URL (already has key): \(apiURL)")
    } else {
        self.flashApiURLString = "\(apiURL)?key=\(apiKey)"
        print("APIService (Flash Gen) configured. URL (appended key): \(self.flashApiURLString)")
    }
  }
   
  func sendAnalysis(image: UIImage, metrics: [String: String]) async throws -> String {
    guard !analysisApiKey.isEmpty, !analysisApiURL.isEmpty else {
      print("Analysis API (separate) not configured. If using Gemini for analysis, ensure its prompt is set correctly elsewhere.")
      throw NSError(domain: "APIService.Analysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Analysis API (separate) not configured."])
    }
    guard let url = URL(string: analysisApiURL) else { throw NSError(domain: "APIService.Analysis", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid Analysis API URL."]) }
    guard let imageData = image.jpegData(compressionQuality: 0.8) else { throw NSError(domain: "APIService.Analysis", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image."]) }
    let requestBody: [String: Any] = ["image": imageData.base64EncodedString(), "metrics": metrics]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(analysisApiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
        throw NSError(domain: "APIService.Analysis", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response. Status: \((response as? HTTPURLResponse)?.statusCode ?? -1). Detail: \(String(data: data, encoding: .utf8) ?? "")"])
    }
    guard let responseString = String(data: data, encoding: .utf8) else { throw NSError(domain: "APIService.Analysis", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response data."]) }
    return responseString
  }

  func generateTextWithGeminiFlash(prompt: String) async throws -> String {
    guard !flashApiURLString.isEmpty else {
        throw NSError(domain: "APIService.GeminiText", code: 201, userInfo: [NSLocalizedDescriptionKey: "Gemini Text API URL not configured."])
    }
    guard let url = URL(string: flashApiURLString) else {
        throw NSError(domain: "APIService.GeminiText", code: 203, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini Text API URL: \(flashApiURLString)"])
    }
    let requestBody: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    print("Sending text generation request to Gemini: \(url.absoluteString)")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else { throw NSError(domain: "APIService.GeminiText", code: 204, userInfo: [NSLocalizedDescriptionKey: "Invalid response object."]) }
    print("Gemini Text API Status Code: \(httpResponse.statusCode)")
    guard (200...299).contains(httpResponse.statusCode) else {
        let errorDetail = String(data: data, encoding: .utf8) ?? "No details"
        print("Gemini Text API Error (\(httpResponse.statusCode)): \(errorDetail)")
        throw NSError(domain: "APIService.GeminiText", code: 205, userInfo: [NSLocalizedDescriptionKey: "Gemini Text API error. Status: \(httpResponse.statusCode). Details: \(errorDetail.prefix(200))"])
    }
    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            let rawResponse = String(data: data, encoding: .utf8) ?? "No raw data"
            print("Could not parse text from Gemini response. Raw: \(rawResponse.prefix(500))")
            throw NSError(domain: "APIService.GeminiText", code: 206, userInfo: [NSLocalizedDescriptionKey: "Could not parse text. Raw: \(rawResponse.prefix(500))"])
        }
        return text
    } catch {
        let rawResponse = String(data: data, encoding: .utf8) ?? "No raw data"
        print("Failed to decode Gemini text response: \(error.localizedDescription). Raw: \(rawResponse.prefix(500))")
        throw NSError(domain: "APIService.GeminiText", code: 207, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response: \(error.localizedDescription). Raw: \(rawResponse.prefix(500))"])
    }
  }

  func sendImageGenerationRequest(referenceImage: UIImage, currentImage: UIImage, prompt: String, additionalMetrics: [String: String]?) async throws -> (String, UIImage?) {
    guard !flashApiURLString.isEmpty else {
        throw NSError(domain: "APIService.FlashGen", code: 101, userInfo: [NSLocalizedDescriptionKey: "Flash 2.0 API URL not configured."])
    }
    guard let url = URL(string: flashApiURLString) else {
        throw NSError(domain: "APIService.FlashGen", code: 103, userInfo: [NSLocalizedDescriptionKey: "Invalid Flash 2.0 API URL: \(flashApiURLString)"])
    }
    guard let refImageData = referenceImage.jpegData(compressionQuality: 0.85),
          let currentImageData = currentImage.jpegData(compressionQuality: 0.8) else {
        throw NSError(domain: "APIService.FlashGen", code: 102, userInfo: [NSLocalizedDescriptionKey: "Failed to convert images to JPEG."])
    }
    let base64RefImage = refImageData.base64EncodedString()
    let base64CurrentImage = currentImageData.base64EncodedString()
    var partsArray: [[String: Any]] = [
        ["text": prompt],
        ["inline_data": ["mime_type": "image/jpeg", "data": base64RefImage]],
        ["inline_data": ["mime_type": "image/jpeg", "data": base64CurrentImage]]
    ]
    let requestPayload: [String: Any] = ["contents": [["parts": partsArray]]]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
    print("Sending multimodal request to Flash Gen API: \(url.absoluteString). Prompt length: \(prompt.count) chars.")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else { throw NSError(domain: "APIService.FlashGen", code: 104, userInfo: [NSLocalizedDescriptionKey: "Invalid response object."]) }
    print("Flash Gen API (Multimodal) Status Code: \(httpResponse.statusCode)")
    guard (200...299).contains(httpResponse.statusCode) else {
        let errorDetail = String(data: data, encoding: .utf8) ?? "No details"
        print("Flash API Error (\(httpResponse.statusCode)): \(errorDetail)")
        throw NSError(domain: "APIService.FlashGen", code: 105, userInfo: [NSLocalizedDescriptionKey: "Flash API error. Status: \(httpResponse.statusCode). Details: \(errorDetail.prefix(500))"])
    }
    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "APIService.FlashGen", code: 107, userInfo: [NSLocalizedDescriptionKey: "Response not valid JSON."])
        }
        var directivesText = "Error: No text part found in Gemini response."
        if let candidates = json["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String {
                    directivesText = text; break
                }
            }
        } else {
             let rawResponse = String(data: data, encoding: .utf8) ?? "No raw data"
             print("Could not parse 'candidates' or 'parts' from Gemini response. Raw: \(rawResponse.prefix(500))")
             directivesText = "Error: Could not parse full response structure. Check logs."
        }
        print("Parsed response from Flash Gen API. Directives: \(directivesText.prefix(100))...")
        return (directivesText, nil)
    } catch {
        let rawResponse = String(data: data, encoding: .utf8) ?? "No raw data"
        print("Failed to decode Flash Gen response: \(error.localizedDescription). Raw: \(rawResponse.prefix(500))")
        throw NSError(domain: "APIService.FlashGen", code: 106, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response: \(error.localizedDescription). Raw: \(rawResponse.prefix(500))"])
    }
  }
}

// MARK: - Potential File: Views/ResponsesView.swift
struct ResponsesView: View {
  @StateObject private var viewModel = ResponsesViewModel()
  @Environment(\.dismiss) var dismiss
  var body: some View {
    NavigationView {
      VStack {
        if viewModel.responses.isEmpty { Text("No responses yet.").foregroundColor(.secondary).padding() }
        else {
            List {
              ForEach(viewModel.responses) { response in
                VStack(alignment: .leading, spacing: 8) {
                  Text("Response from \(response.timestamp, style: .relative)").font(.caption2).foregroundColor(.secondary)
                  Text(response.response).font(.body).lineLimit(nil).textSelection(.enabled)
                }.padding(.vertical, 4)
              }.onDelete(perform: viewModel.deleteResponse)
            }
        }
      }
      .navigationTitle("Service Responses").toolbar {
        ToolbarItem(placement: .navigationBarLeading) { EditButton() }
        ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
      }
      .refreshable { await viewModel.loadResponsesAsync() }
      .onAppear { Task { await viewModel.loadResponsesAsync() } }
    }
  }
}
class ResponsesViewModel: ObservableObject {
  @Published var responses: [APIResponse] = []
  private let userDefaultsKey = "savedPolarisOneResponses"
  func loadResponsesAsync() async {
    DispatchQueue.main.async {
        if let data = UserDefaults.standard.data(forKey: self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode([APIResponse].self, from: data) {
          self.responses = decoded.sorted(by: { $0.timestamp > $1.timestamp })
        } else { self.responses = [] }
    }
  }
  func saveResponse(_ response: APIResponse) {
    responses.insert(response, at: 0); responses.sort(by: { $0.timestamp > $1.timestamp })
    if responses.count > 50 { responses = Array(responses.prefix(50)) }
    if let encoded = try? JSONEncoder().encode(responses) { UserDefaults.standard.set(encoded, forKey: userDefaultsKey) }
  }
  func deleteResponse(at offsets: IndexSet) {
      responses.remove(atOffsets: offsets)
      if let encoded = try? JSONEncoder().encode(responses) { UserDefaults.standard.set(encoded, forKey: userDefaultsKey) }
  }
}

// MARK: - Reference Image Handling (Model, Manager, ViewModel, Picker, Selector)
struct ReferenceImageMetadata: Codable, Equatable {
    var distanceFromCamera: String
    var distanceBelowEyeline: String
    var cameraHeight: String
    static var empty: ReferenceImageMetadata { ReferenceImageMetadata(distanceFromCamera: "", distanceBelowEyeline: "", cameraHeight: "") }
}

struct ReferenceImage: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let dateAdded: Date
    var metadata: ReferenceImageMetadata
    var image: UIImage? { UIImage(contentsOfFile: ReferenceImageManager.shared.url(for: filename).path) }
    
    static func == (lhs: ReferenceImage, rhs: ReferenceImage) -> Bool {
        lhs.id == rhs.id
    }
}

class ReferenceImageManager {
    static let shared = ReferenceImageManager()
    private let key = "referenceImages_v2"
    private let folder = "ReferenceImages"
    private var folderURL: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(folder)
        if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }
    func url(for filename: String) -> URL { folderURL.appendingPathComponent(filename) }
    func saveImage(_ image: UIImage, metadata: ReferenceImageMetadata) -> ReferenceImage? {
        let id = UUID(); let filename = "refimg_\(id.uuidString).jpg"; let url = self.url(for: filename)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: url)
            let ref = ReferenceImage(id: id, filename: filename, dateAdded: Date(), metadata: metadata)
            var refs = loadImages(); refs.append(ref); saveImages(refs); return ref
        } catch { print("Failed to save ref image: \(error)"); return nil }
    }
    func loadImages() -> [ReferenceImage] {
        (try? JSONDecoder().decode([ReferenceImage].self, from: UserDefaults.standard.data(forKey: key) ?? Data())) ?? []
    }
    func saveImages(_ refs: [ReferenceImage]) { if let data = try? JSONEncoder().encode(refs) { UserDefaults.standard.set(data, forKey: key) } }
    func deleteImage(_ ref: ReferenceImage) { try? FileManager.default.removeItem(at: url(for: ref.filename)); saveImages(loadImages().filter { $0.id != ref.id }) }
}

class ReferenceImageViewModel: ObservableObject {
    @Published var images: [ReferenceImage] = []
    @Published var selected: ReferenceImage?
    @Published var showPicker = false
    @Published var showSelector = false
    @Published var showMetadataInput = false
    @Published var pendingImage: UIImage? = nil
    @Published var metadataInput = ReferenceImageMetadata.empty
    
    private let selectedKey = "selectedRefImg_v2"

    init() { load(); loadSelection() }
    
    func load() {
        images = ReferenceImageManager.shared.loadImages().sorted(by: { $0.dateAdded > $1.dateAdded })
        if let selId = selected?.id, !images.contains(where: { $0.id == selId }) {
            selected = images.first
            saveSelection()
        } else if selected == nil && !images.isEmpty {
             // loadSelection() is called in init
        }
    }
    
    func add(image: UIImage, metadata: ReferenceImageMetadata) {
        if let ref = ReferenceImageManager.shared.saveImage(image, metadata: metadata) {
            images.insert(ref, at: 0)
            images.sort(by: { $0.dateAdded > $1.dateAdded })
            select(ref)
        }
    }
    
    func select(_ ref: ReferenceImage?) {
        selected = ref
        saveSelection()
    }
    
    func delete(_ ref: ReferenceImage) {
        ReferenceImageManager.shared.deleteImage(ref)
        images.removeAll { $0.id == ref.id }
        if selected?.id == ref.id {
            selected = images.first
            saveSelection()
        }
    }
    
    func saveSelection() {
        if let sel = selected, let data = try? JSONEncoder().encode(sel.id) {
            UserDefaults.standard.set(data, forKey: selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }
    
    func loadSelection() {
        if let data = UserDefaults.standard.data(forKey: selectedKey),
           let selId = try? JSONDecoder().decode(UUID.self, from: data) {
            selected = images.first(where: { $0.id == selId }) ?? images.first
        } else if !images.isEmpty {
            selected = images.first
        } else {
            selected = nil
        }
    }
}

struct ReferenceImageSelector: View {
    @ObservedObject var vm: ReferenceImageViewModel
    @Environment(\.dismiss) var dismissSheet

    var body: some View {
        NavigationView {
            List {
                ForEach(vm.images) { ref in
                    HStack(alignment: .top) {
                        if let img = ref.image {
                            Image(uiImage: img).resizable().scaledToFit().frame(width: 60, height: 60).cornerRadius(8)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Added: \(ref.dateAdded, formatter: dateFormatter)").font(.caption)
                            if vm.selected == ref {
                                Text("Selected").font(.caption2).bold().foregroundColor(.accentColor)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Dist: \(ref.metadata.distanceFromCamera.isEmpty ? "N/A" : ref.metadata.distanceFromCamera)m").font(.caption2)
                                Text("Eyeline: \(ref.metadata.distanceBelowEyeline.isEmpty ? "N/A" : ref.metadata.distanceBelowEyeline)m").font(.caption2)
                                Text("Cam Height: \(ref.metadata.cameraHeight.isEmpty ? "N/A" : ref.metadata.cameraHeight)m").font(.caption2)
                            }
                        }
                        Spacer()
                        if vm.selected != ref {
                            Button("Select") { vm.select(ref); dismissSheet() }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.select(ref); dismissSheet() }
                }
                .onDelete(perform: { offsets in
                    offsets.map { vm.images[$0] }.forEach { vm.delete($0) }
                })
            }
            .navigationTitle("Reference Images")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { vm.showPicker = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismissSheet() }
                }
            }
            .sheet(isPresented: $vm.showPicker) {
                ImagePicker { img in
                    vm.pendingImage = img
                    vm.metadataInput = ReferenceImageMetadata.empty
                    vm.showMetadataInput = true
                }
            }
            .sheet(isPresented: $vm.showMetadataInput) {
                ReferenceImageMetadataInputView(vm: vm)
            }
            .onAppear {
                vm.load()
            }
        }
    }
}

struct ReferenceImageMetadataInputView: View {
    @ObservedObject var vm: ReferenceImageViewModel
    @State private var distanceFromCamera: String = ""
    @State private var distanceBelowEyeline: String = ""
    @State private var cameraHeight: String = ""
    
    @Environment(\.dismiss) var dismissInputSheet

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Reference Image Metadata (Optional)")) {
                    TextField("Approx. subject distance from camera (m)", text: $distanceFromCamera)
                        .keyboardType(.decimalPad)
                    TextField("Approx. camera below subject's eyeline (m)", text: $distanceBelowEyeline)
                        .keyboardType(.decimalPad)
                    TextField("Approx. camera height from floor (m)", text: $cameraHeight)
                        .keyboardType(.decimalPad)
                }
                 Text("These values help the AI understand the reference photo's perspective. Provide estimates if exact values are unknown. You can leave them blank.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .navigationTitle("Add Metadata")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismissInputSheet()
                        vm.pendingImage = nil
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let meta = ReferenceImageMetadata(
                            distanceFromCamera: distanceFromCamera,
                            distanceBelowEyeline: distanceBelowEyeline,
                            cameraHeight: cameraHeight
                        )
                        if let img = vm.pendingImage {
                            vm.add(image: img, metadata: meta)
                        }
                        dismissInputSheet()
                        vm.pendingImage = nil
                    }
                }
            }
        }
        .onAppear {
            distanceFromCamera = vm.metadataInput.distanceFromCamera
            distanceBelowEyeline = vm.metadataInput.distanceBelowEyeline
            cameraHeight = vm.metadataInput.cameraHeight
        }
    }
}
private let dateFormatter: DateFormatter = { let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short; return df }()

// MARK: - Box Placement (Model, ViewModel, UI)
struct PlacedBox: Identifiable, Codable, Equatable { let id: UUID; let offset: SIMD3<Float>; let dateAdded: Date }
class BoxPlacementViewModel: ObservableObject {
    @Published var boxes: [PlacedBox] = []; @Published var showBoxInput = false; @Published var inputX="0.0"; @Published var inputY="0.0"; @Published var inputZ="0.0"
    func addBox(x: Float, y: Float, z: Float) { boxes.append(PlacedBox(id: UUID(), offset: .init(x,y,z), dateAdded: Date())) }
    func deleteBox(_ box: PlacedBox) { boxes.removeAll { $0.id == box.id } }
}
struct BoxPlacementPanel: View {
    @ObservedObject var vm: BoxPlacementViewModel; var onAdd: (PlacedBox)->Void; var onDelete: (PlacedBox)->Void
    @Environment(\.dismiss) var dismiss
    var body: some View { NavigationView { VStack(spacing:16) {
        HStack { TextField("X (R+)",text:$vm.inputX); TextField("Y (U+)",text:$vm.inputY); TextField("Z (F+)",text:$vm.inputZ)}.keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
        HStack(spacing:12){Label("+X:Right",systemImage:"arrow.right");Label("+Y:Up",systemImage:"arrow.up");Label("+Z:Fwd",systemImage:"arrow.up.right")}.font(.caption2).foregroundColor(.secondary)
        Button("Place Box"){guard let x=Float(vm.inputX),let y=Float(vm.inputY),let z=Float(vm.inputZ)else{return};let box=PlacedBox(id:UUID(),offset:.init(x,y,z),dateAdded:Date());vm.addBox(x:x,y:y,z:z);onAdd(box)}.buttonStyle(.borderedProminent)
        List{ForEach(vm.boxes){box in HStack{Text(String(format:"x:%.1f,y:%.1f,z:%.1f",box.offset.x,box.offset.y,box.offset.z));Spacer();Button(role:.destructive){vm.deleteBox(box);onDelete(box)}label:{Image(systemName:"trash")}}}}
    }.padding().navigationTitle("Box Placement").toolbar{ToolbarItem(placement:.navigationBarLeading){Button("Done"){ dismiss() }}}}}
}

// MARK: - SIMD Quaternion Helper
extension simd_quatf {
    init(from: SIMD3<Float>, to: SIMD3<Float>) {
        let nFrom = normalize(from); let nTo = normalize(to); let axis = cross(nFrom, nTo)
        let angle = acos(min(max(dot(nFrom, nTo), -1), 1))
        if simd.length(axis) < 0.0001 { self = simd_quatf(angle: dot(nFrom, nTo) > 0 ? 0 : .pi, axis: [0,1,0]) }
        else { self = simd_quatf(angle: angle, axis: normalize(axis)) }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImagePicked(img) }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

