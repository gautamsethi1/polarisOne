//
//  ARKitCameraApp.swift
//  polarisOne
//
//  Created by Gautam Sethi on 4/19/25.
//
/*
 ARKitCameraApp.swift – Self‑contained SwiftUI + RealityKit demo
 -----------------------------------------------------------------
 • Live plane & mesh visualisation
 • Body detection with distance calculation
 • One‑tap USDZ export via share‑sheet (LiDAR only)
 -----------------------------------------------------------------
 Xcode 15 / iOS 17. Run on a real device (A12 Bionic+).

 NOTE: This code can exist in a single file, but comments below
       suggest a possible multi-file organization structure.
*/
//
// ARKitCameraApp.swift
// polarisOne
//
/*
 ARKitCameraApp.swift – Self‑contained SwiftUI + RealityKit demo
 -----------------------------------------------------------------
 • Live plane & mesh visualisation
 • Body detection with distance calculation
 • One‑tap USDZ export via share‑sheet (LiDAR only)
 • Integrated call to Flash 2.0 Image Generation Model
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
import Metal // For MTLVertexFormat <<--- ADDED IMPORT
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
  @Published var distanceToPerson: String = "Looking for subjects..." // e.g., "1.5 m"
  @Published var detectedSubjectCount: Int = 0

  @Published var cameraHeightRelativeToEyes: String = "Eyes: N/A"
  @Published var generalCameraHeight: String = "Cam Height: N/A" // e.g., "Cam Height: 0.9 m (Floor)"
  @Published var visibleBodyPartsInfo: String = "Visible Parts: N/A"
  @Published var bodyTrackingHint: String = ""
  @Published var isBodyTrackingActive: Bool = false
   
  @Published var isCapturing: Bool = false // For existing analysis
  @Published var showResponses: Bool = false // For text responses from any service

  // --- NEW PROPERTIES FOR IMAGE GENERATION ---
  @Published var referencePhoto: UIImage? = UIImage(named: "reference_placeholder") // Add "reference_placeholder.png" to Assets.xcassets
  @Published var generatedImage: UIImage?
  @Published var isGeneratingPhoto: Bool = false // Loading state for Flash 2.0 call
  // @Published var showGeneratedPhotoSheet: Bool = false // If you want a dedicated sheet for new image

  // Calibration state
  var calibratedCameraHeight: Float = 0.0
  var isCalibrated: Bool = false
  var distanceCalibrationFactor: Float = 1.0
  var heightMeasurements: [Float] = []
  var distanceMeasurements: [Float] = []
  let maxMeasurements = 5
  // Add a published property to trigger calibration reset
  @Published var calibrationResetTrigger: Bool = false

  func resetCalibration() {
    calibratedCameraHeight = 0.0
    isCalibrated = false
    heightMeasurements.removeAll()
    distanceMeasurements.removeAll()
    calibrationResetTrigger.toggle() // Notify Coordinator to reset its state
  }

  func captureAndAnalyze() { // This is the pre-existing analysis function
    guard let arView = ARMeshExporter.arView else { return }
     
    isCapturing = true
     
    let metrics: [String: String] = [
      "Distance": distanceToPerson,
      "Camera Height": generalCameraHeight,
      "Height Relative to Eyes": cameraHeightRelativeToEyes,
      "Visible Body Parts": visibleBodyPartsInfo,
      "Subject Count": "\(detectedSubjectCount)"
    ]
     
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let image = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }
     
    Task {
      do {
        let response = try await APIService.shared.sendAnalysis(image: image, metrics: metrics)
        let apiResponse = APIResponse(response: response) // Use your existing APIResponse struct
         
        await MainActor.run {
          let viewModel = ResponsesViewModel() // Assuming you have this for displaying/saving text
          viewModel.saveResponse(apiResponse)
          isCapturing = false
          showResponses = true // Show text responses in the existing view
        }
      } catch {
        print("Error sending analysis: \(error)")
        await MainActor.run {
          isCapturing = false
          // Optionally, show an error to the user
          self.bodyTrackingHint = "Analysis failed: \(error.localizedDescription)"
        }
      }
    }
  }

  // --- NEW FUNCTION FOR FLASH 2.0 IMAGE GENERATION ---
  func generateImprovedPhoto() {
    guard let arView = ARMeshExporter.arView else {
      print("ARView not available for image generation.")
      self.bodyTrackingHint = "AR system not ready."
      return
    }
    
    guard let refPhoto = referencePhoto else {
        print("Reference photo (Photo 1) is missing.")
        self.bodyTrackingHint = "Please select a reference photo first."
        // TODO: Implement UI for selecting/providing Photo 1
        return
    }

    isGeneratingPhoto = true
    self.generatedImage = nil // Clear previous generated image

    // 1. Capture Photo 2 (current ARView screen)
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let photo2 = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }

    // 2. Extract metadata in METRIC system
    // Distance: e.g., "1.5 m" -> extract "1.5"
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]
    // generalCameraHeight: e.g., "Cam Height: 0.92 m (Floor)" -> extract "0.92"
    var cameraHeightStringValue: String = "N/A"
    let heightComponents = generalCameraHeight.components(separatedBy: .whitespaces)
    if heightComponents.count > 2 { // Should be ["Cam", "Height:", "X.XXm",...] or ["Cam", "Height:", "X.XX", "m", ...]
        let rawHeightValue = heightComponents[2].replacingOccurrences(of: "m", with: "")
        if Double(rawHeightValue) != nil {
            cameraHeightStringValue = rawHeightValue
        }
    }
    
    // 3. Construct the specific prompt using METRIC units
    let prompt = """
    Act like a photographer who is helping me take a better photo of myself with my iphone. I will provide 2 photos, the first photo is the reference photo, and the second represents what the current photo looks like:
    I want Photo 2 to resemble Photo 1, it does not need to be exact, but try to show the subject with a similar perspective & angle.
    Reply in ≤80 words, listing exactly six directives—one per DOF—plus an optional better‑angle tip. For each:
    • Left/Right (x) – "Move ___ m left/right or 'no movement'"
    • Up/Down (y) – "Move ___ m up/down or 'no movement'"
    • Forward/Back (z) – "Move ___ m forward/back or 'no movement'"
    • Yaw (pan) – "Turn ___ degrees left/right or 'no rotation'"
    • Pitch (tilt) – "Tilt ___ degrees up/down or 'no tilt'"
    • Roll – "Roll ___ degrees clockwise/counter-clockwise or 'no roll'"
    Use precise numbers (meters & degrees).
    Scenario:
    Photo 1: subject approximately 0.8-0.9 m from camera, camera 0.9 m high.
    Photo 2: subject \(distanceStringValue) m from camera, camera \(cameraHeightStringValue) m high.
    I want Photo 2 to resemble Photo 1, it does not need to be exact, but try to show the subject with a similar perspective & angle.
    """

    // 4. Prepare other metadata (optional, if your API can use it)
    let currentMetrics: [String: String] = [
        "distance_to_person_meters": distanceStringValue,
        "camera_height_meters": cameraHeightStringValue,
        "camera_height_raw_string": generalCameraHeight, // "Cam Height: X.XXm (Origin/Floor)"
        "camera_height_relative_to_eyes": cameraHeightRelativeToEyes, // "Eyes: Camera X.XXm Above/Below Subject"
        "visible_body_parts": visibleBodyPartsInfo,
        "detected_subject_count": "\(detectedSubjectCount)"
    ]

    // 5. Call the APIService
    Task {
        do {
            let (directivesText, returnedImage) = try await APIService.shared.sendImageGenerationRequest(
                referenceImage: refPhoto,
                currentImage: photo2,
                prompt: prompt,
                additionalMetrics: currentMetrics
            )
            
            let apiResponse = APIResponse(response: directivesText) // Save textual directives

            await MainActor.run {
                let responsesVM = ResponsesViewModel()
                responsesVM.saveResponse(apiResponse) // Save to existing responses list
                
                self.generatedImage = returnedImage // Store the new image if API returned one
                self.isGeneratingPhoto = false
                self.showResponses = true // Show the text directives in the existing sheet
                // self.showGeneratedPhotoSheet = true // If you create a dedicated view for the image
            }
        } catch {
            print("Error sending image generation request: \(error.localizedDescription)")
            await MainActor.run {
                self.isGeneratingPhoto = false
                self.bodyTrackingHint = "Photo Gen failed: \(error.localizedDescription.prefix(50))..."
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

  var body: some View {
    ZStack(alignment: .topLeading) {
      ARViewContainer(viewModel: vm).ignoresSafeArea()

      // Overlay for various AR information
      VStack(alignment: .leading, spacing: 8) {
        // Reference image display
        if let ref = refVM.selected, let img = ref.image {
          Button(action: { refVM.showSelector = true }) {
            Image(uiImage: img)
              .resizable()
              .scaledToFit()
              .frame(width: 120, height: 120)
              .cornerRadius(12)
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2))
              .shadow(radius: 4)
          }
          .padding(.bottom, 8)
          .accessibilityLabel("Reference Image. Tap to change.")
        } else {
          Button(action: { refVM.showSelector = true }) {
            VStack {
              Image(systemName: "photo.on.rectangle")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundColor(.gray)
              Text("Add Reference Image")
                .font(.caption)
            }
            .frame(width: 120, height: 120)
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
          }
          .padding(.bottom, 8)
        }
        // Add Reset Calibration button
        Button(action: { vm.resetCalibration() }) {
          Label("Reset Calibration", systemImage: "arrow.counterclockwise")
            .font(.caption)
            .padding(6)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding(.bottom, 8)
        if !vm.bodyTrackingHint.isEmpty {
          Text(vm.bodyTrackingHint)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .foregroundColor(.red)
            .font(.caption)
        }

        Text("Subjects: \(vm.detectedSubjectCount)")
          .infoStyle()

        Text(vm.distanceToPerson)
          .infoStyle()

        Text(vm.cameraHeightRelativeToEyes)
          .infoStyle()

        Text(vm.generalCameraHeight)
          .infoStyle()

        Text(vm.visibleBodyPartsInfo)
          .infoStyle()
          .lineLimit(3)

        Spacer()
      }
      .padding()

      // --- Bottom Aligned Content ---
      VStack {
        Spacer()
        
        // --- Optional: Display Generated Image Preview ---
        if let generatedImg = vm.generatedImage {
            Image(uiImage: generatedImg)
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray, lineWidth: 1))
                .padding(.bottom, 5)
                .onTapGesture {
                    // Maybe show a larger preview
                    // vm.showGeneratedPhotoSheet = true
                }
        }


        HStack(spacing: 15) { // Adjusted spacing
          Spacer()

          // Existing Analyze button (wand.and.stars)
          Button(action: {
            vm.captureAndAnalyze()
          }) {
            Image(systemName: "wand.and.stars")
              .font(.system(size: 22, weight: .semibold)) // Slightly smaller for more buttons
              .padding()
              .background(.ultraThinMaterial, in: Circle())
              .accessibilityLabel("Analyze Scene")
          }
          .disabled(vm.isCapturing || vm.isGeneratingPhoto)
          .opacity(vm.isCapturing || vm.isGeneratingPhoto ? 0.5 : 1.0)
           
          // --- NEW: Image Generation Button ---
          Button(action: {
            if vm.referencePhoto == nil {
                vm.bodyTrackingHint = "Error: Set reference photo first."
                return
            }
            vm.generateImprovedPhoto()
          }) {
            Image(systemName: "camera.filters")
              .font(.system(size: 22, weight: .semibold))
              .padding()
              .background(.ultraThinMaterial, in: Circle())
              .accessibilityLabel("Generate Improved Photo")
          }
          .disabled(vm.isCapturing || vm.isGeneratingPhoto || !vm.isBodyTrackingActive || vm.detectedSubjectCount == 0 || vm.referencePhoto == nil)
          .opacity((vm.isCapturing || vm.isGeneratingPhoto || !vm.isBodyTrackingActive || vm.detectedSubjectCount == 0 || vm.referencePhoto == nil) ? 0.5 : 1.0)
           
          // Existing Export Button
          Button(action: {
            if !vm.isBodyTrackingActive {
              vm.shareURL = ARMeshExporter.exportCurrentScene()
            }
          }) {
            Image(systemName: "square.and.arrow.up")
              .font(.system(size: 22, weight: .semibold))
              .padding()
              .background(.ultraThinMaterial, in: Circle())
              .accessibilityLabel("Export Scene")
          }
          .disabled(vm.isBodyTrackingActive || !ARMeshExporter.hasMesh || vm.isCapturing || vm.isGeneratingPhoto)
          .opacity((vm.isBodyTrackingActive || !ARMeshExporter.hasMesh || vm.isCapturing || vm.isGeneratingPhoto) ? 0.5 : 1.0)
          
          Spacer()
        }
        .padding(.bottom, 10)
      }
      .padding(.horizontal) // Add horizontal padding to bottom controls
    }
    .sheet(item: $vm.shareURL) { url in ActivityView(activityItems: [url]) }
    .sheet(isPresented: $vm.showResponses) { // Shows text directives from either service
      ResponsesView()
    }
    .sheet(isPresented: $refVM.showSelector) {
      ReferenceImageSelector(vm: refVM)
        .onDisappear { refVM.load() }
    }
    .onAppear {
      if !ARBodyTrackingConfiguration.isSupported {
        vm.bodyTrackingHint = "ARBodyTracking not supported."
      }
      // --- IMPORTANT: Configure APIService ---
      // Replace with your actual keys and URLs.
      // This should ideally be done once, e.g., in App's init or AppDelegate.
      APIService.shared.configure(
        apiKey: "", // If you have one
        apiURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=GEMINI_API_KEY"  // If you have one
      )
      APIService.shared.configureFlash(
        apiKey: "", // <<-- REPLACE this with your own API key --------- Michael
        apiURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=GEMINI_API_KEY"   // <<-- REPLACE
      )
      
      // Ensure placeholder image is loaded, or prompt user
      if vm.referencePhoto == nil {
          vm.bodyTrackingHint = "Tip: Set a reference photo for image generation."
          // In a real app, you might trigger a PHPicker here or show a button
      }
    }
  }
}

// Helper for styling the info text
struct InfoTextStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.vertical, 5)
      .padding(.horizontal, 10)
      .background(.ultraThinMaterial)
      .cornerRadius(8)
      .font(.caption)
  }
}

extension View {
  func infoStyle() -> some View {
    self.modifier(InfoTextStyle())
  }
}

// MARK: - Potential File: Views/ARViewContainer.swift
// MARK: – UIViewRepresentable wrapping RealityKit
struct ARViewContainer: UIViewRepresentable {
  @ObservedObject var viewModel: ARViewModel

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
      configuration.planeDetection = [.horizontal] // Keep plane detection for general height
      // You might want to enable environmentTexturing or other features
      // configuration.environmentTexturing = .automatic
      view.session.run(configuration)
      // Set hasMesh to true by default if not body tracking, to allow export of scanned environment
      ARMeshExporter.hasMesh = true // Or manage based on ARMeshAnchor presence
    }

    // view.debugOptions.formUnion([.showWorldOrigin, .showAnchorOrigins, .showFeaturePoints]) // More debug info

    let coach = ARCoachingOverlayView()
    coach.session = view.session
    coach.goal = .tracking // .anyPlane or .horizontalPlane if not body tracking
    coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    coach.frame = view.bounds
    view.addSubview(coach)

    return view
  }

  func updateUIView(_ uiView: ARView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(vm: viewModel)
  }

  // MARK: - Coordinator (ARSessionDelegate)
  final class Coordinator: NSObject, ARSessionDelegate {
    private var vm: ARViewModel
    weak var arView: ARView?
    private var currentBodyAnchor: ARBodyAnchor?
    private var initialCameraHeight: Float?
    private var calibrationSamples: [Float] = []
    private let requiredCalibrationSamples = 3
    private var heightSmoothingFactor: Float = 0.2
    private var distanceSmoothingFactor: Float = 0.2
    private var cancellables: Set<AnyCancellable> = []
     
    init(vm: ARViewModel) {
      self.vm = vm
      super.init()
      // Listen for calibration reset
      vm.$calibrationResetTrigger.sink { [weak self] _ in
        self?.resetCalibration()
      }.store(in: &cancellables)
      print("Coordinator Initialized")
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      calculateGeneralCameraHeight(cameraTransform: frame.camera.transform, frame: frame)

      guard let bodyAnchor = self.currentBodyAnchor, vm.isBodyTrackingActive else {
        if vm.detectedSubjectCount > 0 && vm.isBodyTrackingActive { // Only reset if we expected a body
            DispatchQueue.main.async {
                self.vm.detectedSubjectCount = 0 // Will be updated by processAnchors if new ones appear
                self.vm.distanceToPerson = "Looking for subjects..."
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
            }
        } else if !vm.isBodyTrackingActive {
            // If body tracking is not active, these fields are irrelevant
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
      let cameraPosition = cameraTransform.translation
      let bodyPosition = bodyTransform.translation
      let distance = simd_distance(cameraPosition, bodyPosition)
      let distanceString = String(format: "%.1f m", distance)

      calculateCameraHeightRelativeToEyes(bodyAnchor: bodyAnchor, cameraTransform: cameraTransform)
      determineVisibleBodyParts(bodyAnchor: bodyAnchor, frame: frame)

      DispatchQueue.main.async {
        if self.vm.distanceToPerson != distanceString {
          self.vm.distanceToPerson = distanceString
        }
      }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
      processAnchors(anchors, session: session, event: "Added")
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
      processAnchors(anchors, session: session, event: "Updated")
    }
     
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
      var bodyAnchorRemoved = false
      if let currentId = self.currentBodyAnchor?.identifier,
        anchors.contains(where: { $0.identifier == currentId }) {
        self.currentBodyAnchor = nil
        bodyAnchorRemoved = true
        print("Tracked body anchor \(currentId) removed.")
      }
      
      // Update general count based on remaining anchors in the frame
      if let currentFrame = session.currentFrame {
         let bodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         DispatchQueue.main.async {
           if self.vm.detectedSubjectCount != bodyAnchorsInFrame.count {
             self.vm.detectedSubjectCount = bodyAnchorsInFrame.count
           }
           if bodyAnchorRemoved && bodyAnchorsInFrame.isEmpty { // If the one we tracked was removed AND no others are left
                self.vm.distanceToPerson = "Looking for subjects..."
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
           } else if bodyAnchorRemoved && !bodyAnchorsInFrame.isEmpty {
               // If our tracked anchor was removed but others exist, select a new one.
               // processAnchors will handle selecting a new currentBodyAnchor if currentBodyAnchor is nil.
               // We might call processAnchors here with bodyAnchorsInFrame or let didUpdate frame handle it.
               // For simplicity, let's re-evaluate currentBodyAnchor.
               self.currentBodyAnchor = bodyAnchorsInFrame.first
               print("Switched to new body anchor: \(self.currentBodyAnchor?.identifier.uuidString ?? "None") after removal.")
           }
         }
      }
    }

    private func processAnchors(_ anchors: [ARAnchor], session: ARSession, event: String) {
      // Handle ARMeshAnchor for the exporter if not in body tracking mode
      // OR if body tracking is active but we want to allow environment scanning too
      for anchor in anchors where anchor is ARMeshAnchor {
          print("----> Found MESH ANCHOR on \(event)")
          DispatchQueue.main.async { ARMeshExporter.hasMesh = true }
          // break // No break, if multiple meshes, hasMesh remains true
      }


      let bodyAnchors = anchors.compactMap { $0 as? ARBodyAnchor }
      if !bodyAnchors.isEmpty {
        print("----> Found \(bodyAnchors.count) BODY ANCHOR(s) on \(event)!")
        // If no current body anchor, or if the current one is no longer in this update, pick the first new one.
        if self.currentBodyAnchor == nil || !anchors.contains(where: { $0.identifier == self.currentBodyAnchor!.identifier }) {
          self.currentBodyAnchor = bodyAnchors.first // Could be more sophisticated in choosing
           print("----> Now Tracking body anchor: \(self.currentBodyAnchor!.identifier)")
        }
      }
       
      // Update total detected subject count from the current frame's state
      if let currentFrame = session.currentFrame {
         let allBodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         DispatchQueue.main.async {
          if self.vm.detectedSubjectCount != allBodyAnchorsInFrame.count {
            self.vm.detectedSubjectCount = allBodyAnchorsInFrame.count
            print("----> Updated Subject Count: \(allBodyAnchorsInFrame.count)")
          }
          // If count is 0, but we thought we had one, clear currentBodyAnchor
          if allBodyAnchorsInFrame.isEmpty && self.currentBodyAnchor != nil {
              self.currentBodyAnchor = nil
              print("----> No body anchors in frame. Cleared currentBodyAnchor.")
          }
         }
      }
    }

    // --- HELPER FUNCTIONS FOR BODY DETAILS ---
    func calculateCameraHeightRelativeToEyes(bodyAnchor: ARBodyAnchor, cameraTransform: matrix_float4x4) {
      guard let headJointTransform = bodyAnchor.skeleton.modelTransform(for: ARKit.ARSkeleton.JointName.head) else {
        DispatchQueue.main.async {
          self.vm.cameraHeightRelativeToEyes = "Eyes: Head Joint N/A"
        }
        return
      }
      processJointForEyeHeight(
        jointModelTransform: headJointTransform,
        bodyAnchorTransform: bodyAnchor.transform,
        cameraTransform: cameraTransform,
        jointName: "Head"
      )
    }

    private func processJointForEyeHeight(jointModelTransform: simd_float4x4, bodyAnchorTransform: simd_float4x4, cameraTransform: simd_float4x4, jointName: String) {
      let jointWorldTransform = bodyAnchorTransform * jointModelTransform
      let jointWorldPosition = jointWorldTransform.translation
      let cameraWorldPosition = cameraTransform.translation

      let estimatedEyeYOffset: Float = -0.1 // meters (approx. 10cm below top of head)
      let estimatedEyeWorldY = jointWorldPosition.y + estimatedEyeYOffset
      let heightDifference = cameraWorldPosition.y - estimatedEyeWorldY
       
      let directionText: String
      if heightDifference > 0.05 {
        directionText = "Above"
      } else if heightDifference < -0.05 {
        directionText = "Below"
      } else {
        directionText = "Level with"
      }
       
      let text = String(format: "Eyes: Cam %.2fm %@ Subject", abs(heightDifference), directionText)
       
      DispatchQueue.main.async {
        if self.vm.cameraHeightRelativeToEyes != text {
          self.vm.cameraHeightRelativeToEyes = text
        }
      }
    }

    func calculateGeneralCameraHeight(cameraTransform: matrix_float4x4, frame: ARFrame) {
      let cameraWorldY = cameraTransform.translation.y
      var text: String

      // Prioritize horizontal planes that are classified as "floor"
      let floorPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
                            .filter { $0.alignment == .horizontal && $0.classification == .floor }
      
      if let floorPlane = floorPlanes.min(by: { $0.transform.translation.y < $1.transform.translation.y }) {
        let floorY = floorPlane.transform.translation.y
        let cameraHeightAboveFloor = cameraWorldY - floorY
        text = String(format: "Cam Height: %.2fm (Floor)", cameraHeightAboveFloor)
      } else {
          // Fallback to any horizontal plane if no floor is classified
          let horizontalPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
          if let anyHorizontalPlane = horizontalPlanes.min(by: { $0.transform.translation.y < $1.transform.translation.y }) {
              let planeY = anyHorizontalPlane.transform.translation.y
              let cameraHeightAbovePlane = cameraWorldY - planeY
              text = String(format: "Cam Height: %.2fm (Plane)", cameraHeightAbovePlane)
          } else {
              text = String(format: "Cam Height: %.2fm (Origin)", cameraWorldY)
          }
      }

      DispatchQueue.main.async {
        if self.vm.generalCameraHeight != text {
          self.vm.generalCameraHeight = text
        }
      }
    }

    func determineVisibleBodyParts(bodyAnchor: ARBodyAnchor, frame: ARFrame) {
      guard let arView = self.arView else {
        DispatchQueue.main.async { self.vm.visibleBodyPartsInfo = "Visible Parts: ARView N/A" }
        return
      }

      var visibleJointsDescriptions: [String] = []
      let viewportSize = arView.bounds.size
      let skeleton = bodyAnchor.skeleton

      let jointsOfInterest: [ARKit.ARSkeleton.JointName] = [
        .head,
        .leftShoulder, .leftHand, .rightShoulder, .rightHand,
        .leftFoot, .rightFoot,
      ]
       
      for jointName in jointsOfInterest {
        guard let jointModelTransform = skeleton.modelTransform(for: jointName) else { continue }
        let jointWorldTransform = bodyAnchor.transform * jointModelTransform
        let jointWorldPosition = jointWorldTransform.translation
        let projectedPoint = arView.project(jointWorldPosition)

        if let screenPoint = projectedPoint {
          let pointInCameraSpace = frame.camera.transform.inverse * SIMD4<Float>(jointWorldPosition.x, jointWorldPosition.y, jointWorldPosition.z, 1.0)
          if pointInCameraSpace.z < 0 && // Check if in front of camera
            screenPoint.x >= 0 && screenPoint.x <= viewportSize.width &&
            screenPoint.y >= 0 && screenPoint.y <= viewportSize.height {
            visibleJointsDescriptions.append(jointName.rawValue.replacingOccurrences(of: "_joint", with: "").replacingOccurrences(of: "_", with: " ").capitalizedFirst())
          }
        }
      }
       
      let text: String
      if !visibleJointsDescriptions.isEmpty {
        text = "Visible: " + visibleJointsDescriptions.prefix(5).joined(separator: ", ") + (visibleJointsDescriptions.count > 5 ? "..." : "")
      } else if vm.detectedSubjectCount > 0 {
         text = "Visible Parts: Subject Occluded/Out of View"
      } else {
        text = "Visible Parts: N/A"
      }

      DispatchQueue.main.async {
        if self.vm.visibleBodyPartsInfo != text {
          self.vm.visibleBodyPartsInfo = text
        }
      }
    }

    // --- ARSessionDelegate Optional Error/Interruption Handling ---
    func session(_ session: ARSession, didFailWithError error: Error) {
      print("❌ AR Session Failed: \(error.localizedDescription)")
      DispatchQueue.main.async {
        self.vm.bodyTrackingHint = "AR Session Failed: \(error.localizedDescription.prefix(50))"
      }
    }

    func sessionWasInterrupted(_ session: ARSession) {
      print("⏸️ AR Session Interrupted")
      DispatchQueue.main.async {
        self.vm.bodyTrackingHint = "AR Session Interrupted. Trying to resume..."
      }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
      print("▶️ AR Session Interruption Ended. Resetting session.")
      // Attempt to re-run the session with the current configuration.
      // This often helps re-establish tracking.
      if let configuration = session.configuration {
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.async {
          self.vm.bodyTrackingHint = self.vm.isBodyTrackingActive ? "Body Tracking Active" : "World Tracking Active"
          self.vm.distanceToPerson = "Looking for subjects..." // Reset state
        }
      } else {
          DispatchQueue.main.async {
            self.vm.bodyTrackingHint = "Session resumed, but config lost."
          }
      }
    }

    private func resetCalibration() {
      initialCameraHeight = nil
      calibrationSamples.removeAll()
      vm.calibratedCameraHeight = 0.0
      vm.isCalibrated = false
      vm.heightMeasurements.removeAll()
      vm.distanceMeasurements.removeAll()
    }
  }
}

// MARK: - Potential File: Extensions/String+Helpers.swift
extension String {
  func capitalizedFirst() -> String {
    return prefix(1).capitalized + dropFirst()
  }
}

// MARK: - Potential File: Utilities/ARMeshExporter.swift
struct ARMeshExporter {
  static weak var arView: ARView?
  static var hasMesh = false

  static func exportCurrentScene() -> URL? {
    guard let view = arView, hasMesh,
       let anchors = view.session.currentFrame?.anchors else {
      print("Export failed: ARView not set, no mesh, or no current anchors.")
      return nil
    }
    let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
    guard !meshAnchors.isEmpty else {
       print("Export failed: No ARMeshAnchors found to export.")
       return nil
    }

    print("Exporting \(meshAnchors.count) mesh anchors...")
    let asset = MDLAsset()
    guard let device = MTLCreateSystemDefaultDevice() else {
      print("Export failed: Could not get default Metal device.")
      return nil
    }
    let allocator = MTKMeshBufferAllocator(device: device)
    meshAnchors.forEach { anchor in
      asset.add(MDLMesh(arMeshAnchor: anchor, allocator: allocator))
    }

    let fileManager = FileManager.default
    guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
      print("Export failed: Could not access documents directory.")
      return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fileName = "Scan_\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).usdz" // Make filename more filesystem-friendly
    let fileURL = documentsDirectory.appendingPathComponent(fileName)

    print("Attempting to export to: \(fileURL.path)")
    do {
      try asset.export(to: fileURL)
      print("✅ Export successful!")
      return fileURL
    } catch {
      print("❌ Export error: \(error.localizedDescription)")
      return nil
    }
  }
}


// MARK: - Potential File: Extensions/Metal+MDLVertexFormat.swift
// Helper to convert MTLVertexFormat (from ARGeometrySource.format) to MDLVertexFormat
extension MTLVertexFormat {
    func toMDLVertexFormat() -> MDLVertexFormat {
        switch self {
        // Float types
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        case .float4: return .float4
        
        // Half float types
        case .half: return .half
        case .half2: return .half2
        case .half3: return .half3
        case .half4: return .half4
            
        // Integer types (signed) - ARKit geometry typically uses floats for vertices/normals/texcoords
        case .char: return .char
        case .char2: return .char2
        case .char3: return .char3
        case .char4: return .char4
        
        case .short: return .short
        case .short2: return .short2
        case .short3: return .short3
        case .short4: return .short4
            
        case .int: return .int
        case .int2: return .int2
        case .int3: return .int3
        case .int4: return .int4
            
        // Integer types (unsigned)
        case .uchar: return .uChar
        case .uchar2: return .uChar2
        case .uchar3: return .uChar3
        case .uchar4: return .uChar4
            
        case .ushort: return .uShort
        case .ushort2: return .uShort2
        case .ushort3: return .uShort3
        case .ushort4: return .uShort4

        case .uint: return .uInt
        case .uint2: return .uInt2
        case .uint3: return .uInt3
        case .uint4: return .uInt4
            
        // Add normalized versions if ARKit starts using them for mesh geometry.
        // For example:
        // case .uchar4Normalized: return .uChar4Normalized
            
        default:
            // This is important: if ARKit introduces a new format for geometry,
            // it needs to be handled here. Log this prominently.
            print("⚠️ Warning: Unhandled MTLVertexFormat raw value \(self.rawValue) in toMDLVertexFormat(). Defaulting to .invalid. Mesh export may be incomplete or incorrect.")
            return .invalid // Using .invalid is safer than guessing. Model I/O might ignore or error.
        }
    }
}


// MARK: - Potential File: Extensions/MDLMesh+ARMeshAnchor.swift
extension MDLMesh {
  convenience init(arMeshAnchor a: ARMeshAnchor, allocator: MTKMeshBufferAllocator) {
    let g = a.geometry
    let vData = Data(bytesNoCopy: g.vertices.buffer.contents(), count: g.vertices.stride * g.vertices.count, deallocator: .none)
    let fData = Data(bytesNoCopy: g.faces.buffer.contents(), count: g.faces.bytesPerIndex * g.faces.count * g.faces.indexCountPerPrimitive, deallocator: .none)

    let vBuf = allocator.newBuffer(with: vData, type: .vertex)
    let iBuf = allocator.newBuffer(with: fData, type: .index)
    let indexCount = g.faces.count * g.faces.indexCountPerPrimitive

    let sub = MDLSubmesh(indexBuffer: iBuf,
               indexCount: indexCount,
               indexType: .uInt32,
               geometryType: .triangles,
               material: nil)

    // ARGeometrySource.format IS MTLVertexFormat. Use the new extension.
    let descriptor = Self.vertexDescriptor(from: g.vertices, normals: g.normals, textureCoordinates: nil) // Pass textureCoordinates if available

    self.init(vertexBuffer: vBuf,
         vertexCount: g.vertices.count,
         descriptor: descriptor,
         submeshes: [sub])
    self.transform = MDLTransform(matrix: a.transform)
  }

  static func vertexDescriptor(from vertices: ARGeometrySource, normals: ARGeometrySource?, textureCoordinates: ARGeometrySource?) -> MDLVertexDescriptor {
    let descriptor = MDLVertexDescriptor()
    var offset = 0 // Assuming tightly packed attributes within each source, or separate buffers.
    // If interleaved within a single buffer, offset calculation would be more complex.
    // ARKit usually provides separate ARGeometrySource instances for positions, normals, texcoords.

    // Position attribute (Always present)
    // vertices.format is MTLVertexFormat, so .toMDLVertexFormat() will call the new extension
    descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                           format: vertices.format.toMDLVertexFormat(), // CORRECTED
                           offset: 0, // Offset within its own buffer data
                           bufferIndex: 0) // Buffer index for positions
    descriptor.layouts[0] = MDLVertexBufferLayout(stride: vertices.stride) // Stride for position buffer

    var currentAttributeIndex = 1
    var currentBufferIndex = 1 // Start next buffer index at 1

    if let normalsSource = normals {
        descriptor.attributes[currentAttributeIndex] = MDLVertexAttribute(name: MDLVertexAttributeNormal,
                                           format: normalsSource.format.toMDLVertexFormat(), // CORRECTED
                                           offset: 0, // Offset within its own buffer data
                                           bufferIndex: currentBufferIndex)
        descriptor.layouts[currentBufferIndex] = MDLVertexBufferLayout(stride: normalsSource.stride)
        currentAttributeIndex += 1
        currentBufferIndex += 1
    }

    if let texCoordsSource = textureCoordinates {
        // ARKit's ARMeshGeometry often doesn't include texture coordinates by default
        // unless generated by a specific scene reconstruction process that does.
        descriptor.attributes[currentAttributeIndex] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                           format: texCoordsSource.format.toMDLVertexFormat(), // CORRECTED
                                           offset: 0, // Offset within its own buffer data
                                           bufferIndex: currentBufferIndex)
        descriptor.layouts[currentBufferIndex] = MDLVertexBufferLayout(stride: texCoordsSource.stride)
        // currentAttributeIndex += 1 // Not needed if it's the last one
        // currentBufferIndex += 1
    }
    
    return descriptor
  }
}

// MARK: - Potential File: Views/ActivityView.swift
struct ActivityView: UIViewControllerRepresentable {
  let activityItems: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }
  func updateUIViewController(_ uiVC: UIActivityViewController, context: Context) {}
}

// MARK: - Potential File: Extensions/SIMD+Helpers.swift
extension simd_float4x4 {
  var translation: simd_float3 {
    return simd_float3(columns.3.x, columns.3.y, columns.3.z)
  }
}

// MARK: - Potential File: Models/APIResponse.swift
struct APIResponse: Identifiable, Codable {
  let id: UUID
  let timestamp: Date
  let response: String
   
  init(response: String) {
    self.id = UUID()
    self.timestamp = Date()
    self.response = response
  }
}

// MARK: - Potential File: Services/APIService.swift
class APIService {
  static let shared = APIService()
  private var apiKey: String = ""
  private var apiURL: String = ""
  private var flashApiKey: String = ""
  private var flashApiURL: String = ""
   
  func configure(apiKey: String, apiURL: String) {
    self.apiKey = apiKey
    self.apiURL = apiURL
    print("APIService (Analysis) configured. URL: \(apiURL.isEmpty ? "Not Set" : apiURL), Key: \(apiKey.isEmpty ? "Not Set" : "Set")")
  }
   
  func configureFlash(apiKey: String, apiURL: String) {
    self.flashApiKey = apiKey
    self.flashApiURL = apiURL
    print("APIService (Flash Gen) configured. URL: \(flashApiURL.isEmpty ? "Not Set" : flashApiURL), Key: \(flashApiKey.isEmpty ? "Not Set" : "Set")")
  }
   
  func sendAnalysis(image: UIImage, metrics: [String: String]) async throws -> String {
    guard !apiKey.isEmpty, !apiURL.isEmpty else {
      throw NSError(domain: "APIService.Analysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Analysis API not configured (URL or Key missing)."])
    }
    guard let url = URL(string: apiURL) else {
      throw NSError(domain: "APIService.Analysis", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid Analysis API URL."])
    }
    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
      throw NSError(domain: "APIService.Analysis", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image for analysis."])
    }
    let base64Image = imageData.base64EncodedString()
    let requestBody: [String: Any] = ["image": base64Image, "metrics": metrics]
     
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
     
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
        let errorDetail = String(data: data, encoding: .utf8) ?? "No error detail."
        throw NSError(domain: "APIService.Analysis", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response from analysis server. Status: \((response as? HTTPURLResponse)?.statusCode ?? -1). Detail: \(errorDetail)"])
    }
    guard let responseString = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "APIService.Analysis", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response data from analysis server."])
    }
    return responseString
  }

  func sendImageGenerationRequest(
    referenceImage: UIImage,
    currentImage: UIImage,
    prompt: String,
    additionalMetrics: [String: String]?
  ) async throws -> (String, UIImage?) {

    guard !flashApiKey.isEmpty, !flashApiURL.isEmpty else {
        throw NSError(domain: "APIService.FlashGen", code: 101, userInfo: [NSLocalizedDescriptionKey: "Flash 2.0 API not configured (URL or Key missing)."])
    }
    guard let url = URL(string: flashApiURL) else {
        throw NSError(domain: "APIService.FlashGen", code: 103, userInfo: [NSLocalizedDescriptionKey: "Invalid Flash 2.0 API URL."])
    }

    guard let refImageData = referenceImage.jpegData(compressionQuality: 0.8),
          let currentImageData = currentImage.jpegData(compressionQuality: 0.8) else {
        throw NSError(domain: "APIService.FlashGen", code: 102, userInfo: [NSLocalizedDescriptionKey: "Failed to convert images to JPEG data for Flash API."])
    }

    let base64RefImage = refImageData.base64EncodedString()
    let base64CurrentImage = currentImageData.base64EncodedString()

    var requestDict: [String: Any] = [
        "prompt": prompt,
        "reference_image_base64": base64RefImage,
        "current_image_base64": base64CurrentImage,
    ]
    if let metrics = additionalMetrics {
        requestDict["metadata"] = metrics
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(flashApiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestDict, options: [])
    
    print("Sending to Flash Gen API: \(flashApiURL). Prompt: \(prompt.prefix(100))...")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(domain: "APIService.FlashGen", code: 104, userInfo: [NSLocalizedDescriptionKey: "Invalid response object from Flash API."])
    }
    
    print("Flash Gen API Status Code: \(httpResponse.statusCode)")

    guard (200...299).contains(httpResponse.statusCode) else {
        let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
        print("Flash Gen API Error (\(httpResponse.statusCode)) Body: \(responseBody)")
        throw NSError(domain: "APIService.FlashGen", code: 105, userInfo: [NSLocalizedDescriptionKey: "Flash API error. Status: \(httpResponse.statusCode). Details: \(responseBody.prefix(200))"])
    }

    do {
        if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            let directivesText = jsonResponse["directives_text"] as? String ?? jsonResponse["text"] as? String ?? "No directives text in Flash API response."
            
            var generatedImage: UIImage? = nil
            if let imageBase64 = jsonResponse["generated_image_base64"] as? String,
               let imgData = Data(base64Encoded: imageBase64) {
                generatedImage = UIImage(data: imgData)
                print("Successfully decoded generated image from Flash API.")
            } else if jsonResponse["generated_image_base64"] != nil {
                print("Warning: 'generated_image_base64' field present but not a valid string or image data in Flash API response.")
            }
            return (directivesText, generatedImage)
        } else {
            if let textResponse = String(data: data, encoding: .utf8) {
                print("Flash API returned non-JSON, treating as plain text directives.")
                return (textResponse, nil)
            }
            throw NSError(domain: "APIService.FlashGen", code: 107, userInfo: [NSLocalizedDescriptionKey: "Flash API response was not valid JSON and not plain text."])
        }
    } catch {
        print("Error decoding Flash API JSON response: \(error.localizedDescription). Raw data: \(String(data: data, encoding: .utf8) ?? "Undecodable")")
        throw NSError(domain: "APIService.FlashGen", code: 106, userInfo: [NSLocalizedDescriptionKey: "Failed to decode Flash API response: \(error.localizedDescription)"])
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
        if viewModel.responses.isEmpty {
            Text("No analysis responses yet.")
                .foregroundColor(.secondary)
                .padding()
        } else {
            List {
              ForEach(viewModel.responses) { response in
                VStack(alignment: .leading, spacing: 8) {
                  Text("Response from \(response.timestamp, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                  Text(response.response)
                    .font(.body)
                    .lineLimit(nil)
                }
                .padding(.vertical, 4)
              }
              .onDelete(perform: viewModel.deleteResponse)
            }
        }
      }
      .navigationTitle("Service Responses")
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
            EditButton()
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done") {
                dismiss()
            }
        }
      }
      .refreshable {
        await viewModel.loadResponsesAsync()
      }
      .onAppear {
          Task { await viewModel.loadResponsesAsync() }
      }
    }
  }
}

// MARK: - Potential File: ViewModels/ResponsesViewModel.swift
class ResponsesViewModel: ObservableObject {
  @Published var responses: [APIResponse] = []
  private let userDefaultsKey = "savedPolarisOneResponses"
   
  init() {
    // Task { await loadResponsesAsync() } // Defer to view's onAppear
  }
   
  func loadResponsesAsync() async {
    DispatchQueue.main.async {
        if let data = UserDefaults.standard.data(forKey: self.userDefaultsKey),
           let decodedResponses = try? JSONDecoder().decode([APIResponse].self, from: data) {
          self.responses = decodedResponses.sorted(by: { $0.timestamp > $1.timestamp })
        } else {
          self.responses = []
        }
    }
  }
   
  func saveResponse(_ response: APIResponse) {
    responses.insert(response, at: 0)
    responses.sort(by: { $0.timestamp > $1.timestamp })

    if let encoded = try? JSONEncoder().encode(responses) {
      UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
    }
  }

  func deleteResponse(at offsets: IndexSet) {
      responses.remove(atOffsets: offsets)
      if let encoded = try? JSONEncoder().encode(responses) {
          UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
      }
  }
}

// MARK: - Reference Image Model & Manager
struct ReferenceImage: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let dateAdded: Date
    
    var image: UIImage? {
        let url = ReferenceImageManager.shared.url(for: filename)
        return UIImage(contentsOfFile: url.path)
    }
}

class ReferenceImageManager {
    static let shared = ReferenceImageManager()
    private let imagesKey = "referenceImages"
    private let folderName = "ReferenceImages"
    
    private var folderURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent(folderName)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
    
    func url(for filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }
    
    func saveImage(_ image: UIImage) -> ReferenceImage? {
        let id = UUID()
        let filename = "refimg_\(id).jpg"
        let url = self.url(for: filename)
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        do {
            try data.write(to: url)
            let ref = ReferenceImage(id: id, filename: filename, dateAdded: Date())
            var refs = loadImages()
            refs.append(ref)
            saveImages(refs)
            return ref
        } catch {
            print("Failed to save image: \(error)")
            return nil
        }
    }
    
    func loadImages() -> [ReferenceImage] {
        guard let data = UserDefaults.standard.data(forKey: imagesKey),
              let refs = try? JSONDecoder().decode([ReferenceImage].self, from: data) else {
            return []
        }
        return refs
    }
    
    func saveImages(_ refs: [ReferenceImage]) {
        if let data = try? JSONEncoder().encode(refs) {
            UserDefaults.standard.set(data, forKey: imagesKey)
        }
    }
    
    func deleteImage(_ ref: ReferenceImage) {
        let url = self.url(for: ref.filename)
        try? FileManager.default.removeItem(at: url)
        var refs = loadImages().filter { $0.id != ref.id }
        saveImages(refs)
    }
}

// MARK: - Reference Image ViewModel
class ReferenceImageViewModel: ObservableObject {
    @Published var images: [ReferenceImage] = []
    @Published var selected: ReferenceImage?
    @Published var showPicker = false
    @Published var showSelector = false
    
    init() {
        load()
    }
    
    func load() {
        images = ReferenceImageManager.shared.loadImages()
        if selected == nil, let first = images.first {
            selected = first
        } else if let sel = selected, !images.contains(where: { $0.id == sel.id }) {
            selected = images.first
        }
    }
    
    func add(image: UIImage) {
        if let ref = ReferenceImageManager.shared.saveImage(image) {
            images.append(ref)
            selected = ref
            saveSelection()
        }
    }
    
    func select(_ ref: ReferenceImage) {
        selected = ref
        saveSelection()
    }
    
    func delete(_ ref: ReferenceImage) {
        ReferenceImageManager.shared.deleteImage(ref)
        images.removeAll { $0.id == ref.id }
        if selected?.id == ref.id {
            selected = images.first
        }
        saveSelection()
    }
    
    func saveSelection() {
        if let sel = selected, let data = try? JSONEncoder().encode(sel) {
            UserDefaults.standard.set(data, forKey: "selectedReferenceImage")
        }
    }
    
    func loadSelection() {
        if let data = UserDefaults.standard.data(forKey: "selectedReferenceImage"),
           let sel = try? JSONDecoder().decode(ReferenceImage.self, from: data) {
            selected = sel
        }
    }
}

// MARK: - Reference Image Picker (UIKit bridge)
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    var onImagePicked: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Reference Image Selector Sheet
struct ReferenceImageSelector: View {
    @ObservedObject var vm: ReferenceImageViewModel
    var body: some View {
        NavigationView {
            List {
                ForEach(vm.images) { ref in
                    HStack {
                        if let img = ref.image {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading) {
                            Text("Added: \(ref.dateAdded, formatter: dateFormatter)")
                                .font(.caption)
                            if vm.selected == ref {
                                Text("Selected").font(.caption2).foregroundColor(.accentColor)
                            }
                        }
                        Spacer()
                        if vm.selected != ref {
                            Button("Select") { vm.select(ref) }
                        }
                        Button(role: .destructive) {
                            vm.delete(ref)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Reference Images")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { vm.showPicker = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { vm.showSelector = false }
                }
            }
            .sheet(isPresented: $vm.showPicker) {
                ImagePicker { img in
                    vm.add(image: img)
                }
            }
        }
    }
}

private let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .short
    return df
}()
