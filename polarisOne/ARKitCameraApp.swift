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
import AVFoundation // Added for AVCaptureDevice
import Vision // For ML-based human detection

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

  
  // --- Settings ---
  @Published var showDetailedMetrics: Bool = true
  @Published var showSettings: Bool = false

  // --- New Camera/Scene Properties ---
  @Published var cameraRoll: Float?
  @Published var cameraPitch: Float?
  @Published var cameraYaw: Float?
  @Published var fieldOfViewHorizontalDeg: Float?
  @Published var ambientIntensityLux: Float?
  @Published var ambientColorTemperatureKelvin: Float?

  // Computed properties for display strings
  var cameraOrientationDegString: String {
    guard let roll = cameraRoll, let pitch = cameraPitch, let yaw = cameraYaw else { return "Orientation: N/A" }
    // ARCamera.eulerAngles provides: pitch (around X), yaw (around Y), roll (around Z).
    // Standard display order is often Roll, Pitch, Yaw.
    // Note: Negating roll to match expected convention (positive roll = clockwise when looking forward)
    return String(format: "R:%.0f° P:%.0f° Y:%.0f°", -roll * 180 / .pi, pitch * 180 / .pi, yaw * 180 / .pi)
  }
  var fieldOfViewDegString: String {
    guard let fov = fieldOfViewHorizontalDeg else { return "FOV H: N/A" }
    return String(format: "FOV H: %.1f°", fov)
  }
  var ambientLuxString: String {
    guard let lux = ambientIntensityLux else { return "Lux: N/A" }
    return String(format: "Lux: %.0f", lux)
  }
  var colorTempKString: String {
    guard let temp = ambientColorTemperatureKelvin else { return "Color K: N/A" }
    return String(format: "Color K: %.0f", temp)
  }
  
  // Store the latest structured response for potential UI use
  @Published var latestStructuredGuidance: StructuredGeminiResponse? = nil
  
  // Subject detection and guidance state
  @Published var currentSubjectBounds: SubjectBounds? = nil
  @Published var activeGuidanceBox: GuidanceBox? = nil
  @Published var isGuidanceActive: Bool = false



  private func getFinalCameraHeightForPrompt() -> (stringValue: String, numericValue: Double?) {
      var cameraHeightStringValue: String = "N/A"
      var numericHeightValue: Double? = nil
      let fullHeightString = generalCameraHeight
      if fullHeightString.lowercased().contains("n/a") {
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
          if generalCameraHeight.lowercased().contains("low?") {
              finalPromptString = "\(cameraHeightStringValue)m (potentially low)"
          } else if numHeight < -0.19 && generalCameraHeight.lowercased().contains("origin") {
              finalPromptString = "approx. 0m (origin likely high or detection issue)"
          } else {
              finalPromptString = "\(cameraHeightStringValue)m"
          }
      } else if cameraHeightStringValue == "N/A" {
          finalPromptString = "unknown (AR not ready)"
      } else if numericHeightValue != nil {
           finalPromptString = "\(cameraHeightStringValue)m"
      }
      return (finalPromptString, numericHeightValue)
  }
  
  func capturePhotoWithMetrics() {
    guard let arView = ARMeshExporter.arView else {
      self.bodyTrackingHint = "AR system not ready for capture."
      return
    }
    
    isCapturing = true
    
    // Capture current AR view
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let capturedImage = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }
    
    // Get current metrics
    let (finalCameraHeightForPrompt, _) = getFinalCameraHeightForPrompt()
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]
    
    // Extract eyeline distance from cameraHeightRelativeToEyes
    var eyelineDistance = ""
    if cameraHeightRelativeToEyes.contains("Cam") && cameraHeightRelativeToEyes.contains("m") {
      let components = cameraHeightRelativeToEyes.components(separatedBy: " ")
      if components.count >= 3 {
        eyelineDistance = components[2].replacingOccurrences(of: "m", with: "")
      }
    }
    
    // Create metadata with all current metrics
    let metadata = ReferenceImageMetadata(
      distanceFromCamera: distanceStringValue,
      distanceBelowEyeline: eyelineDistance,
      cameraHeight: finalCameraHeightForPrompt.replacingOccurrences(of: "m", with: "").replacingOccurrences(of: " (unknown AR not ready)", with: ""),
      cameraHeightRelativeToEyes: cameraHeightRelativeToEyes,
      visibleBodyParts: visibleBodyPartsInfo,
      detectedSubjectCount: "\(detectedSubjectCount)",
      cameraRollDeg: cameraRoll != nil ? String(format: "%.1f", -cameraRoll! * 180 / .pi) : "N/A",
      cameraPitchDeg: cameraPitch != nil ? String(format: "%.1f", cameraPitch! * 180 / .pi) : "N/A",
      cameraYawDeg: cameraYaw != nil ? String(format: "%.1f", cameraYaw! * 180 / .pi) : "N/A",
      cameraFOVHDeg: fieldOfViewHorizontalDeg != nil ? String(format: "%.1f", fieldOfViewHorizontalDeg!) : "N/A",
      ambientLux: ambientIntensityLux != nil ? String(format: "%.0f", ambientIntensityLux!) : "N/A",
      colorTempK: ambientColorTemperatureKelvin != nil ? String(format: "%.0f", ambientColorTemperatureKelvin!) : "N/A",
      captureDate: Date()
    )
    
    // Save to reference images
    if let savedRef = ReferenceImageManager.shared.saveImage(capturedImage, metadata: metadata) {
      DispatchQueue.main.async {
        self.selectedReferenceImage = savedRef
        self.bodyTrackingHint = "Photo captured with metrics and saved to library"
        self.isCapturing = false
        
        // Notify reference view model to reload if it exists
        NotificationCenter.default.post(name: Notification.Name("RefreshReferenceImages"), object: nil)
      }
    } else {
      DispatchQueue.main.async {
        self.bodyTrackingHint = "Failed to save captured photo"
        self.isCapturing = false
      }
    }
  }
  
  func analyzeScene() {
    guard let arView = ARMeshExporter.arView else {
      self.bodyTrackingHint = "AR system not ready."
      return
    }
    
    isCapturing = true
    
    // Capture current AR view
    let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
    let currentImage = renderer.image { ctx in
      arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
    }
    
    // Get reference image if available
    let referenceImage: UIImage
    let hasReference = selectedReferenceImage?.image != nil
    
    if let refImageContainer = selectedReferenceImage, let refImage = refImageContainer.image {
      referenceImage = refImage
    } else {
      // Use current image as both reference and current if no reference is set
      referenceImage = currentImage
    }
    
    // Prepare metrics
    let (finalCameraHeightForPrompt, _) = getFinalCameraHeightForPrompt()
    let distanceStringValue = distanceToPerson.components(separatedBy: " ")[0]
    
    let rollDeg = cameraRoll != nil ? String(format: "%.1f", -cameraRoll! * 180 / .pi) : "N/A"
    let pitchDeg = cameraPitch != nil ? String(format: "%.1f", cameraPitch! * 180 / .pi) : "N/A"
    let yawDeg = cameraYaw != nil ? String(format: "%.1f", cameraYaw! * 180 / .pi) : "N/A"
    let orientationPrompt = "R:\(rollDeg)°, P:\(pitchDeg)°, Y:\(yawDeg)°"
    
    var currentMetrics: [String: String] = [
        "distance_to_person_meters": distanceStringValue,
        "camera_height_meters": finalCameraHeightForPrompt,
        "camera_height_raw_string": generalCameraHeight,
        "camera_height_relative_to_eyes": cameraHeightRelativeToEyes,
        "visible_body_parts": visibleBodyPartsInfo,
        "detected_subject_count": "\(detectedSubjectCount)",
        "camera_roll_deg": rollDeg,
        "camera_pitch_deg": pitchDeg,
        "camera_yaw_deg": yawDeg,
        "camera_fov_h_deg": fieldOfViewHorizontalDeg != nil ? String(format: "%.1f", fieldOfViewHorizontalDeg!) : "N/A",
        "ambient_lux": ambientIntensityLux != nil ? String(format: "%.0f", ambientIntensityLux!) : "N/A",
        "color_temp_k": ambientColorTemperatureKelvin != nil ? String(format: "%.0f", ambientColorTemperatureKelvin!) : "N/A"
    ]
    
    // Build prompt based on whether we have a reference image
    let prompt: String
    
    if hasReference, let refImageContainer = selectedReferenceImage {
      // We have a reference image - provide comparison guidance
      let refMeta = refImageContainer.metadata
      let distCam = refMeta.distanceFromCamera.isEmpty ? "N/A" : "\(refMeta.distanceFromCamera)m"
      let camHeight = refMeta.cameraHeight.isEmpty ? "N/A" : "\(refMeta.cameraHeight)m"
      let belowEyeline = refMeta.distanceBelowEyeline.isEmpty ? "N/A" : "\(refMeta.distanceBelowEyeline)m (camera below subject's eyes)"
      
      let photo1Details = """
      - Subject distance from camera: \(distCam)
      - Camera height: \(camHeight)
      - Camera position relative to subject's eyeline: \(belowEyeline)
      - Visible body parts: \(refMeta.visibleBodyParts.isEmpty ? "N/A" : refMeta.visibleBodyParts)
      - Detected subject count: \(refMeta.detectedSubjectCount.isEmpty ? "N/A" : refMeta.detectedSubjectCount)
      - Camera Orientation (Roll, Pitch, Yaw): R:\(refMeta.cameraRollDeg)°, P:\(refMeta.cameraPitchDeg)°, Y:\(refMeta.cameraYawDeg)°
      - Camera Horizontal FOV: \(refMeta.cameraFOVHDeg.isEmpty ? "N/A" : "\(refMeta.cameraFOVHDeg)°")
      - Ambient Light: \(refMeta.ambientLux.isEmpty ? "N/A" : "\(refMeta.ambientLux) lux")
      - Color Temperature: \(refMeta.colorTempK.isEmpty ? "N/A" : "\(refMeta.colorTempK)K")
      """
      
      let photo2Details = """
      - Subject distance from camera: \(distanceStringValue.isEmpty ? "N/A" : "\(distanceStringValue)m")
      - Camera height: \(finalCameraHeightForPrompt)
      - Camera height relative to subject's eyes: \(cameraHeightRelativeToEyes)
      - Visible body parts: \(visibleBodyPartsInfo)
      - Detected subject count: \(detectedSubjectCount)
      - Camera Orientation (Roll, Pitch, Yaw): \(orientationPrompt)
      - Camera Horizontal FOV: \(self.fieldOfViewDegString)
      - Ambient Light: \(self.ambientLuxString)
      - Color Temperature: \(self.colorTempKString)
      """
      
      prompt = """
      You are an expert photography assistant. Your goal is to help me adjust my iPhone camera position and angle to make the live camera view (Photo 2) look as close as possible to a reference image (Photo 1).

      I will provide two images:
      1. Photo 1: The reference image I want to emulate. (This will be the first image in the payload)
      2. Photo 2: The current live view from my iPhone camera. (This will be the second image in the payload)

      Reference Photo Details (Photo 1):
      \(photo1Details)

      Current Scene Details (Photo 2):
      \(photo2Details)

      Based on these two images and their details, provide precise directives to adjust my iPhone (Photo 2) to better match Photo 1's perspective, angle, and subject framing.
      
      IMPORTANT: Respond ONLY with valid JSON in the following exact format:
      
      {
        "adjustments": {
          "translation": {
            "x": {
              "direction": "left|right|no change",
              "magnitude": 0.5,
              "unit": "m",
              "description": "Move 0.5m left"
            },
            "y": {
              "direction": "up|down|no change",
              "magnitude": 0.2,
              "unit": "m",
              "description": "Move 0.2m up"
            },
            "z": {
              "direction": "forward|back|no change",
              "magnitude": 1.0,
              "unit": "m",
              "description": "Move 1.0m forward"
            }
          },
          "rotation": {
            "yaw": {
              "direction": "left|right|no change",
              "magnitude": 15,
              "unit": "deg",
              "description": "Turn 15° left"
            },
            "pitch": {
              "direction": "up|down|no change",
              "magnitude": 5,
              "unit": "deg",
              "description": "Tilt 5° up"
            },
            "roll": {
              "direction": "clockwise|counter-clockwise|no change",
              "magnitude": 0,
              "unit": "deg",
              "description": "No roll adjustment needed"
            }
          }
        },
        "summary": "Brief summary of key adjustments",
        "confidence": 0.85
      }
      
      Rules:
      - For "no change" directions, set magnitude to 0 or null
      - Use precise numeric values
      - Keep descriptions concise
      - Confidence is a value between 0 and 1
      - Respond with ONLY the JSON, no additional text
      """
    } else {
      // No reference image - just analyze the current scene
      prompt = """
      Act like an expert ARKit scene analyst and photography coach. I will provide a photo of the current AR scene and measured values about the subject and camera.
      
      Please provide a concise analysis (≤100 words) that includes:
      1. Assessment of the current scene composition
      2. Specific suggestions for improving the photo (positioning, angle, distance)
      3. Any detected issues with tracking or visibility
      4. Tips for better photo results
      
      Scene metrics:
      - Subject distance: \(distanceStringValue) m
      - Camera height: \(finalCameraHeightForPrompt)
      - Height relative to eyes: \(cameraHeightRelativeToEyes)
      - Visible body parts: \(visibleBodyPartsInfo)
      - Detected subject count: \(detectedSubjectCount)
      - Camera Orientation (Roll, Pitch, Yaw): \(orientationPrompt)
      - Camera Horizontal FOV: \(self.fieldOfViewDegString)
      - Ambient Light: \(self.ambientLuxString)
      - Color Temperature: \(self.colorTempKString)
      """
    }
    
    Task {
      do {
        if hasReference {
          // Use structured response for reference image comparison
          let (structuredResponse, rawJSON) = try await APIService.shared.sendStructuredImageComparisonRequest(
            referenceImage: referenceImage,
            currentImage: currentImage,
            prompt: prompt,
            additionalMetrics: currentMetrics
          )
          
          // Format the structured response into human-readable text
          var formattedResponse = "Photo Guidance (6 DOF Adjustments):\n\n"
          
          // Translation adjustments
          formattedResponse += "POSITION ADJUSTMENTS:\n"
          formattedResponse += "• X-axis: \(structuredResponse.adjustments.translation.x.description)\n"
          formattedResponse += "• Y-axis: \(structuredResponse.adjustments.translation.y.description)\n"
          formattedResponse += "• Z-axis: \(structuredResponse.adjustments.translation.z.description)\n\n"
          
          // Rotation adjustments
          formattedResponse += "ROTATION ADJUSTMENTS:\n"
          formattedResponse += "• Yaw: \(structuredResponse.adjustments.rotation.yaw.description)\n"
          formattedResponse += "• Pitch: \(structuredResponse.adjustments.rotation.pitch.description)\n"
          formattedResponse += "• Roll: \(structuredResponse.adjustments.rotation.roll.description)\n"
          
          if let summary = structuredResponse.summary {
            formattedResponse += "\nSUMMARY: \(summary)"
          }
          
          if let confidence = structuredResponse.confidence {
            formattedResponse += "\nConfidence: \(Int(confidence * 100))%"
          }
          
          let apiResponse = APIResponse(response: formattedResponse)
          
          await MainActor.run {
            let viewModel = ResponsesViewModel()
            viewModel.saveResponse(apiResponse)
            isCapturing = false
            showResponses = true
            
            // Store the structured guidance for potential UI use
            self.latestStructuredGuidance = structuredResponse
            
            // Trigger guidance box creation if we have subject bounds
            if let subjectBounds = self.currentSubjectBounds {
              print("✅ Subject bounds available, creating guidance box")
              self.activateGuidanceBox(for: structuredResponse, subjectBounds: subjectBounds)
            } else {
              print("❌ No subject bounds available - cannot create guidance box")
              print("💡 Ensure a human subject is detected before analyzing scene")
            }
            
            // Show brief hint with key adjustment
            var keyAdjustment = "Check responses for guidance"
            if let summary = structuredResponse.summary {
              keyAdjustment = String(summary.prefix(60)) + "..."
            }
            self.bodyTrackingHint = "Photo Guidance: \(keyAdjustment)"
          }
        } else {
          // Use regular text response for scene analysis without reference
          let (responseText, _) = try await APIService.shared.sendImageGenerationRequest(
            referenceImage: referenceImage,
            currentImage: currentImage,
            prompt: prompt,
            additionalMetrics: currentMetrics
          )
          
          let apiResponse = APIResponse(response: "Scene Analysis:\n\(responseText)")
          
          await MainActor.run {
            let viewModel = ResponsesViewModel()
            viewModel.saveResponse(apiResponse)
            isCapturing = false
            showResponses = true
            
            // Show brief hint
            let previewText = responseText.prefix(60)
            self.bodyTrackingHint = "Scene Analysis: \(previewText)... (See Responses)"
          }
        }
      } catch {
        print("Error sending analysis request: \(error)")
        await MainActor.run {
          isCapturing = false
          self.bodyTrackingHint = "Analysis failed: \(error.localizedDescription)"
        }
      }
    }
  }
  
  // Activate guidance box based on LLM recommendations
  func activateGuidanceBox(for guidance: StructuredGeminiResponse, subjectBounds: SubjectBounds) {
    guard let arView = ARMeshExporter.arView else { 
      print("❌ activateGuidanceBox: ARView is nil")
      return 
    }
    
    print("✅ activateGuidanceBox called with subject at: \(subjectBounds.center)")
    
    // Calculate subject-relative offset based on LLM recommendations
    let cameraTransform = arView.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
    
    let relativeOffset = GuidanceBoxService.shared.calculateSubjectRelativeOffset(
      currentSubjectBounds: subjectBounds,
      recommendations: guidance.adjustments,
      cameraTransform: cameraTransform
    )
    
    print("📍 Subject-relative offset calculated: \(relativeOffset)")
    print("📏 Offset magnitude: \(simd_length(relativeOffset))m")
    
    // Create guidance box with subject-relative positioning
    let guidanceBox = GuidanceBoxService.shared.createGuidanceBox(
      relativeOffset: relativeOffset,
      subjectBounds: subjectBounds,
      recommendations: guidance.adjustments
    )
    
    print("📦 Guidance box created with size: \(guidanceBox.size)")
    
    // Update state
    activeGuidanceBox = guidanceBox
    isGuidanceActive = true
    
    // Show in AR view
    GuidanceBoxRenderer.shared.showGuidanceBox(guidanceBox, in: arView)
    
    bodyTrackingHint = "Guidance active: Green box follows subject position"
    print("✅ Guidance box should now be visible")
  }
  
  // Toggle guidance on/off
  func toggleGuidance() {
    guard let arView = ARMeshExporter.arView else { return }
    
    if isGuidanceActive {
      // Hide guidance
      GuidanceBoxRenderer.shared.hideGuidanceBox(in: arView)
      isGuidanceActive = false
      activeGuidanceBox = nil
      bodyTrackingHint = "Guidance disabled"
    } else {
      // Try to reactivate guidance if we have data
      if let guidance = latestStructuredGuidance,
         let subjectBounds = currentSubjectBounds {
        activateGuidanceBox(for: guidance, subjectBounds: subjectBounds)
      } else {
        bodyTrackingHint = "No guidance data available. Analyze scene first."
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

      VStack(alignment: .leading, spacing: 6) { // Reduced spacing
        if let refContainer = vm.selectedReferenceImage, let img = refContainer.image {
          Button(action: { refVM.showSelector = true }) {
            Image(uiImage: img)
              .resizable().scaledToFit().frame(width: 100, height: 100) // Smaller ref image
              .cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5))
              .shadow(radius: 3)
          }.padding(.bottom, 6).accessibilityLabel("Reference Image. Tap to change.")
        } else {
          Button(action: { refVM.showSelector = true }) {
            VStack {
              Image(systemName: "photo.on.rectangle").resizable().scaledToFit().frame(width: 50, height: 50).foregroundColor(.gray)
              Text("Add Reference").font(.caption2) // Smaller text
            }.frame(width: 100, height: 100).background(Color(.systemGray6)).cornerRadius(10)
             .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3])))
          }.padding(.bottom, 6)
        }
        // Box placement button removed for brevity if not critical path, or make smaller
        // Button(action: { boxVM.showBoxInput = true }) {
        //     Label("Box Placement", systemImage: "cube").font(.caption).padding(6).background(Color(.systemGray6)).cornerRadius(8)
        // }.padding(.bottom, 8)
        

        if !vm.bodyTrackingHint.isEmpty {
          Text(vm.bodyTrackingHint)
            .padding(.vertical, 4).padding(.horizontal, 8) // Smaller padding
            .background(.ultraThinMaterial).cornerRadius(6)
            .foregroundColor(
                vm.bodyTrackingHint.lowercased().contains("error") ||
                vm.bodyTrackingHint.lowercased().contains("failed") ||
                vm.bodyTrackingHint.lowercased().contains("auto-reset") ? .red : .primary
            ).font(.caption2).lineLimit(2) // Smaller font
        }
        
        // Only show detailed metrics if enabled in settings
        if vm.showDetailedMetrics {
          Text("Humans: \(vm.detectedSubjectCount)").infoStyle(fontSize: .caption2)
          Text(vm.distanceToPerson).infoStyle(fontSize: .caption2)
          Text(vm.cameraHeightRelativeToEyes).infoStyle(fontSize: .caption2, lineLimit: 2)
          Text(vm.generalCameraHeight).infoStyle(fontSize: .caption2, lineLimit: 2)
          Text(vm.visibleBodyPartsInfo).infoStyle(fontSize: .caption2, lineLimit: 2)
          
          // --- New Info Displays ---
          Text(vm.cameraOrientationDegString).infoStyle(fontSize: .caption2)
          Text(vm.fieldOfViewDegString).infoStyle(fontSize: .caption2)
          Text(vm.ambientLuxString).infoStyle(fontSize: .caption2)
          Text(vm.colorTempKString).infoStyle(fontSize: .caption2)
        }

      }
      .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)) // Adjusted padding

      VStack {
        Spacer()
        
        // Camera capture button - iPhone style
        Button(action: { vm.capturePhotoWithMetrics() }) {
          ZStack {
            Circle()
              .fill(Color.white)
              .frame(width: 70, height: 70)
            Circle()
              .strokeBorder(Color.white, lineWidth: 3)
              .frame(width: 80, height: 80)
          }
        }
        .disabled(vm.isCapturing || vm.isGeneratingPhoto)
        .opacity((vm.isCapturing || vm.isGeneratingPhoto) ? 0.5 : 1.0)
        .padding(.bottom, 30)
        
        HStack(spacing: 20) {
          // Settings button
          Button(action: { vm.showSettings = true }) {
            Image(systemName: "gear").font(.system(size: 22, weight: .semibold))
              .frame(width: 42, height: 42)
              .background(.ultraThinMaterial, in: Circle())
              .foregroundColor(.white)
          }
          
          // Guidance toggle button
          Button(action: { vm.toggleGuidance() }) {
            Image(systemName: vm.isGuidanceActive ? "cube.fill" : "cube")
              .font(.system(size: 22, weight: .semibold))
              .frame(width: 42, height: 42)
              .background(.ultraThinMaterial, in: Circle())
              .foregroundColor(vm.isGuidanceActive ? .green : .white)
          }
          .disabled(vm.isCapturing || vm.isGeneratingPhoto)
          .opacity((vm.isCapturing || vm.isGeneratingPhoto) ? 0.5 : 1.0)
          
          Spacer()
          
          // Analyze scene button
          Button(action: { vm.analyzeScene() }) {
            Image(systemName: "wand.and.stars").font(.system(size: 22, weight: .semibold))
              .frame(width: 42, height: 42)
              .background(.ultraThinMaterial, in: Circle())
              .foregroundColor(.white)
          }
          .disabled(vm.isCapturing || vm.isGeneratingPhoto)
          .opacity((vm.isCapturing || vm.isGeneratingPhoto) ? 0.5 : 1.0)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 20)
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
    .sheet(isPresented: $vm.showSettings) {
      SettingsView(viewModel: vm)
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
        apiURL: "YOUR_ANALYSIS_ENDPOINT_URL_IF_ANY"
      )
      
      let geminiAPIKey = EnvHelper.value(for: "GEMINI_API_KEY")
      let geminiBaseURLForFlashModel = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-05-20:generateContent"
      
      print("Gemini API Key loaded: \(geminiAPIKey.isEmpty ? "NOT FOUND" : "Found (\(geminiAPIKey.prefix(8))...)")")
      
      APIService.shared.configureFlash(
        apiKey: geminiAPIKey,
        apiURL: geminiBaseURLForFlashModel
      )
      
      vm.selectedReferenceImage = refVM.selected
      if vm.selectedReferenceImage == nil { vm.bodyTrackingHint = "Tip: Set a reference photo for image generation." }
    }
  }
}

struct InfoTextStyle: ViewModifier {
    var fontSize: Font = .caption
    var lineLimit: Int? = 1

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3) // Reduced padding
            .padding(.horizontal, 6) // Reduced padding
            .background(.ultraThinMaterial)
            .cornerRadius(5) // Slightly smaller corner radius
            .font(fontSize)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion if lineLimit > 1
    }
}
extension View {
    func infoStyle(fontSize: Font = .caption, lineLimit: Int? = 1) -> some View {
        self.modifier(InfoTextStyle(fontSize: fontSize, lineLimit: lineLimit))
    }
}


// MARK: - Potential File: Views/ARViewContainer.swift
struct ARViewContainer: UIViewRepresentable {
  @ObservedObject var viewModel: ARViewModel
  @ObservedObject var boxVM: BoxPlacementViewModel

  func makeUIView(context: Context) -> ARView {
    let view = ARView(frame: .zero)
    ARMeshExporter.arView = view
    context.coordinator.arView = view
    view.session.delegate = context.coordinator

    context.coordinator.fetchInitialCameraFOV()

    if ARBodyTrackingConfiguration.isSupported {
      let configuration = ARBodyTrackingConfiguration()
      configuration.automaticSkeletonScaleEstimationEnabled = true
      configuration.planeDetection = [.horizontal]
      configuration.isLightEstimationEnabled = true // Enable light estimation
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
      configuration.isLightEstimationEnabled = true // Enable light estimation
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
    
    // Smoothing buffers for measurements
    private var distanceBuffer: [Float] = []
    private var heightBuffer: [Float] = []
    private let bufferSize = 3 // Reduced for more responsive updates
    
    // Validation cache for fast human detection
    private var validationCache: [UUID: Bool] = [:]
     
    init(vm: ARViewModel, boxVM: BoxPlacementViewModel) {
      self.vm = vm
      self.boxVM = boxVM
      super.init()
      boxVM.$boxes.sink { [weak self] boxes in self?.syncBoxes(boxes) }.store(in: &cancellables)
      print("Coordinator Initialized")
    }
      
    func fetchInitialCameraFOV() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Accessing AVCaptureDevice directly for ARKit's active format is not straightforward.
            // This is a best-effort attempt; ARKit might use different settings.
            // For a more accurate FOV used by ARKit, one might need to rely on camera intrinsics
            // or other ARFrame properties if available and convert them.
            // `AVCaptureDevice.activeFormat.videoFieldOfView` gives the FoV for the *current* active format
            // of the default video device, which ARKit *likely* uses or configures similarly.
            if let device = AVCaptureDevice.default(for: .video) {
                let fov = device.activeFormat.videoFieldOfView // This is Float
                DispatchQueue.main.async {
                    self.vm.fieldOfViewHorizontalDeg = fov
                }
            } else {
                DispatchQueue.main.async {
                    self.vm.fieldOfViewHorizontalDeg = nil
                }
            }
        }
    }

      
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      calculateGeneralCameraHeight(cameraTransform: frame.camera.transform, frame: frame)
      
      // Update camera orientation (eulerAngles are in radians: pitch, yaw, roll)
      let eulerAngles = frame.camera.eulerAngles
      let newPitchRad = eulerAngles.x // Pitch around X-axis
      let newYawRad = eulerAngles.y   // Yaw around Y-axis
      let newRollRad = eulerAngles.z  // Roll around Z-axis

      // Update light estimates
      var newAmbientLux: Float? = nil
      var newColorTempK: Float? = nil
      if let lightEstimate = frame.lightEstimate {
          // CORRECTED: Cast CGFloat to Float
          newAmbientLux = Float(lightEstimate.ambientIntensity)
          newColorTempK = Float(lightEstimate.ambientColorTemperature)
      }
      
      // Enhanced subject detection combining ARKit and Vision
      updateSubjectDetection(frame: frame)

      DispatchQueue.main.async {
          // Update ViewModel properties if they changed
          // Values are stored in radians in VM, converted to degrees in computed string
          if self.vm.cameraPitch != newPitchRad { self.vm.cameraPitch = newPitchRad }
          if self.vm.cameraYaw != newYawRad { self.vm.cameraYaw = newYawRad }
          if self.vm.cameraRoll != newRollRad { self.vm.cameraRoll = newRollRad }
          
          if self.vm.ambientIntensityLux != newAmbientLux { self.vm.ambientIntensityLux = newAmbientLux }
          if self.vm.ambientColorTemperatureKelvin != newColorTempK { self.vm.ambientColorTemperatureKelvin = newColorTempK }
      }

      guard let bodyAnchor = self.currentBodyAnchor, vm.isBodyTrackingActive else {
        if vm.detectedSubjectCount > 0 && vm.isBodyTrackingActive {
            DispatchQueue.main.async {
                self.vm.detectedSubjectCount = 0
                self.vm.distanceToPerson = "Looking for humans..."
                self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"
                self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
            }
            // Clear smoothing buffers when tracking is lost
            distanceBuffer.removeAll()
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
      let cameraPosition = cameraTransform.translation
      
      // Calculate distance using multiple body joints for better accuracy
      var distances: [Float] = []
      
      // Try to get hip/root position (most stable)
      if let hipTransform = bodyAnchor.skeleton.modelTransform(for: .root) {
        let hipWorldPos = (bodyAnchor.transform * hipTransform).translation
        distances.append(simd_distance(cameraPosition, hipWorldPos))
      }
      
      // Also consider left and right shoulder for averaging (forms chest center)
      if let leftShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .leftShoulder),
         let rightShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .rightShoulder) {
        let leftShoulderPos = (bodyAnchor.transform * leftShoulderTransform).translation
        let rightShoulderPos = (bodyAnchor.transform * rightShoulderTransform).translation
        // Calculate chest center as midpoint between shoulders
        let chestCenter = SIMD3<Float>(
          (leftShoulderPos.x + rightShoulderPos.x) / 2,
          (leftShoulderPos.y + rightShoulderPos.y) / 2,
          (leftShoulderPos.z + rightShoulderPos.z) / 2
        )
        distances.append(simd_distance(cameraPosition, chestCenter))
      }
      
      // Fall back to body anchor transform if no joints available
      if distances.isEmpty {
        let bodyPosition = bodyAnchor.transform.translation
        distances.append(simd_distance(cameraPosition, bodyPosition))
      }
      
      // Average the distances for more stable measurement
      let averageDistance = distances.reduce(0, +) / Float(distances.count)
      
      // Add to smoothing buffer
      distanceBuffer.append(averageDistance)
      if distanceBuffer.count > bufferSize {
        distanceBuffer.removeFirst()
      }
      
      // Calculate smoothed distance
      let smoothedDistance = distanceBuffer.reduce(0, +) / Float(distanceBuffer.count)
      
      // Format distance with appropriate precision
      let distanceString: String
      if smoothedDistance < 1.0 {
        distanceString = String(format: "%.2f m", smoothedDistance) // More precision for close distances
      } else {
        distanceString = String(format: "%.1f m", smoothedDistance)
      }
      
      calculateCameraHeightRelativeToEyes(bodyAnchor: bodyAnchor, cameraTransform: cameraTransform)
      determineVisibleBodyParts(bodyAnchor: bodyAnchor, frame: frame)
      
      // Calculate subject bounds from ARKit body tracking
      if let subjectBounds = SubjectDetectionService.shared.calculateARSubjectBounds(from: bodyAnchor) {
        DispatchQueue.main.async {
          self.vm.currentSubjectBounds = subjectBounds
          
          // Update guidance box position to follow subject if active
          if self.vm.isGuidanceActive,
             let arView = self.arView {
            // Update box position based on current subject movement using the new subject-anchored system
            GuidanceBoxRenderer.shared.updateBoxPositionForSubject(subjectBounds: subjectBounds, in: arView)
          }
        }
      }
      
      DispatchQueue.main.async {
        // Always update for fresh values
        self.vm.distanceToPerson = distanceString
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
      
      // Clean up validation cache for removed anchors
      for anchor in anchors {
        validationCache.removeValue(forKey: anchor.identifier)
      }
      if let currentFrame = session.currentFrame {
         let bodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         DispatchQueue.main.async {
           if self.vm.detectedSubjectCount != bodyAnchorsInFrame.count { self.vm.detectedSubjectCount = bodyAnchorsInFrame.count }
           if bodyAnchorRemoved && bodyAnchorsInFrame.isEmpty {
                self.vm.distanceToPerson = "Looking for humans..."; self.vm.cameraHeightRelativeToEyes = "Eyes: N/A"; self.vm.visibleBodyPartsInfo = "Visible Parts: N/A"
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
      
      // Filter body anchors to only include validated humans
      let bodyAnchors = anchors.compactMap { $0 as? ARBodyAnchor }
      let validatedHumanAnchors = bodyAnchors.filter { validateHumanBody($0) }
      
      if !validatedHumanAnchors.isEmpty {
        print("----> Found \(validatedHumanAnchors.count) VALIDATED HUMAN(s) on \(event)!")
        if self.currentBodyAnchor == nil || !anchors.contains(where: { $0.identifier == self.currentBodyAnchor!.identifier }) {
          self.currentBodyAnchor = validatedHumanAnchors.first
           print("----> Now Tracking human body anchor: \(self.currentBodyAnchor!.identifier)")
        }
      }
      
      if let currentFrame = session.currentFrame {
         let allBodyAnchorsInFrame = currentFrame.anchors.compactMap { $0 as? ARBodyAnchor }
         let validatedHumansInFrame = allBodyAnchorsInFrame.filter { validateHumanBody($0) }
         
         DispatchQueue.main.async {
          if self.vm.detectedSubjectCount != validatedHumansInFrame.count {
            self.vm.detectedSubjectCount = validatedHumansInFrame.count
            print("----> Updated Human Subject Count: \(validatedHumansInFrame.count)")
          }
          if validatedHumansInFrame.isEmpty && self.currentBodyAnchor != nil {
              self.currentBodyAnchor = nil
              print("----> No validated human bodies in frame. Cleared currentBodyAnchor.")
          }
         }
      }
    }
    
    // Validate that a body anchor represents a real human - FAST & PRACTICAL
    private func validateHumanBody(_ bodyAnchor: ARBodyAnchor) -> Bool {
      // Trust ARKit completely - it already filters for humans
      let trustARKitCompletely = true
      
      if trustARKitCompletely {
        // ARKit body tracking only detects humans, so any body anchor is valid
        return true
      }
      
      // Optional validation (disabled by default for speed)
      // Cache validation results to avoid repeated checks
      if let cachedResult = validationCache[bodyAnchor.identifier] {
        return cachedResult
      }
      
      let skeleton = bodyAnchor.skeleton
      
      // Fast check: Just verify we have at least 2 joints
      var jointCount = 0
      let minJoints = 2
      
      // Check only the most important joints first
      if skeleton.modelTransform(for: .head) != nil { jointCount += 1 }
      if jointCount >= minJoints { 
        validationCache[bodyAnchor.identifier] = true
        return true 
      }
      
      if skeleton.modelTransform(for: .root) != nil { jointCount += 1 }
      if jointCount >= minJoints { 
        validationCache[bodyAnchor.identifier] = true
        return true 
      }
      
      if skeleton.modelTransform(for: .leftShoulder) != nil { jointCount += 1 }
      if jointCount >= minJoints { 
        validationCache[bodyAnchor.identifier] = true
        return true 
      }
      
      if skeleton.modelTransform(for: .rightShoulder) != nil { jointCount += 1 }
      
      let isValid = jointCount >= minJoints
      validationCache[bodyAnchor.identifier] = isValid
      
      if !isValid {
        print("Body validation failed: Only \(jointCount) joints tracked")
      }
      
      return isValid
    }

    func calculateCameraHeightRelativeToEyes(bodyAnchor: ARBodyAnchor, cameraTransform: matrix_float4x4) {
      // Try to get head joint first
      guard let headJointTransform = bodyAnchor.skeleton.modelTransform(for: .head) else {
        // Fallback: try to estimate from shoulders
        if let leftShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .leftShoulder),
           let rightShoulderTransform = bodyAnchor.skeleton.modelTransform(for: .rightShoulder) {
          let leftShoulderPos = (bodyAnchor.transform * leftShoulderTransform).translation
          let rightShoulderPos = (bodyAnchor.transform * rightShoulderTransform).translation
          let shoulderCenter = SIMD3<Float>(
            (leftShoulderPos.x + rightShoulderPos.x) / 2,
            (leftShoulderPos.y + rightShoulderPos.y) / 2,
            (leftShoulderPos.z + rightShoulderPos.z) / 2
          )
          let cameraWorldPosition = cameraTransform.translation
          // Estimate eye position from shoulder center (typically ~25-30cm above shoulders)
          let estimatedEyeWorldY = shoulderCenter.y + 0.28
          let heightDifference = cameraWorldPosition.y - estimatedEyeWorldY
          let directionText = heightDifference > 0.05 ? "Above" : (heightDifference < -0.05 ? "Below" : "Level with")
          let text = String(format: "Eyes: Cam %.2fm %@ Subject", abs(heightDifference), directionText)
          DispatchQueue.main.async {
            // Always update for fresh values
            self.vm.cameraHeightRelativeToEyes = text
          }
          return
        }
        DispatchQueue.main.async { self.vm.cameraHeightRelativeToEyes = "Eyes: Head Joint N/A" }
        return
      }
      
      let headWorldTransform = bodyAnchor.transform * headJointTransform
      let headWorldPosition = headWorldTransform.translation
      let cameraWorldPosition = cameraTransform.translation
      
      // More accurate eye offset estimation based on head joint
      // Head joint is typically at the center of the head, eyes are ~5-8cm below and forward
      let estimatedEyeYOffset: Float = -0.07 // Refined offset from head joint center to eye level
      let estimatedEyeWorldY = headWorldPosition.y + estimatedEyeYOffset
      
      let heightDifference = cameraWorldPosition.y - estimatedEyeWorldY
      let directionText: String
      if abs(heightDifference) < 0.05 {
        directionText = "Level with"
      } else if heightDifference > 0 {
        directionText = "Above"
      } else {
        directionText = "Below"
      }
      
      let text = String(format: "Eyes: Cam %.2fm %@ Subject", abs(heightDifference), directionText)
      DispatchQueue.main.async {
        // Always update for fresh values
        self.vm.cameraHeightRelativeToEyes = text
      }
    }

    func calculateGeneralCameraHeight(cameraTransform: matrix_float4x4, frame: ARFrame) {
        let cameraWorldY = cameraTransform.translation.y
        var text: String
        
        // Simple approach - find the lowest horizontal plane (floor or table)
        let floorPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal && ($0.classification == .floor || $0.classification == .table) }
        
        if let floorPlane = floorPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
            let height = cameraWorldY - floorPlane.transform.translation.y
            if height < -0.1 {
                text = String(format: "Cam Height: %.2fm (Low?)", height)
            } else {
                text = String(format: "Cam Height: %.2fm (\(floorPlane.classification == .floor ? "Floor" : "Table"))", height)
            }
        } else {
            // No classified floor/table, try any horizontal plane
            let horizontalPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
                .filter { $0.alignment == .horizontal }
            
            if let anyHorizontalPlane = horizontalPlanes.min(by: { abs($0.transform.translation.y) < abs($1.transform.translation.y) }) {
                let height = cameraWorldY - anyHorizontalPlane.transform.translation.y
                if height < -0.1 {
                    text = String(format: "Cam Height: %.2fm (Plane - Low?)", height)
                } else {
                    text = String(format: "Cam Height: %.2fm (Plane)", height)
                }
            } else {
                // No planes detected, height relative to origin
                text = String(format: "Cam Height: %.2fm (Origin)", cameraWorldY)
            }
        }
        
        DispatchQueue.main.async {
            // Always update to ensure fresh values
            self.vm.generalCameraHeight = text
        }
    }

    func determineVisibleBodyParts(bodyAnchor: ARBodyAnchor, frame: ARFrame) {
      guard let arView = self.arView else { DispatchQueue.main.async { self.vm.visibleBodyPartsInfo = "Visible Parts: ARView N/A" }; return }
      var visibleJointsDescriptions: [String] = []
      let jointsOfInterest: [ARKit.ARSkeleton.JointName] = [.head, .leftShoulder, .leftHand, .rightShoulder, .rightHand, .leftFoot, .rightFoot, .root] // .root is hip/pelvis area
      for jointName in jointsOfInterest {
        guard let jointModelTransform = bodyAnchor.skeleton.modelTransform(for: jointName) else { continue }
        let jointWorldPosition = (bodyAnchor.transform * jointModelTransform).translation
        
        // Project point to screen space
        if let screenPoint = arView.project(jointWorldPosition) {
          // Check if point is in front of camera (z < 0 in camera space) and within screen bounds
          let pointInCameraSpace = frame.camera.transform.inverse * SIMD4<Float>(jointWorldPosition.x, jointWorldPosition.y, jointWorldPosition.z, 1.0)
          if pointInCameraSpace.z < 0 && // Point is in front of the camera
             screenPoint.x >= arView.bounds.minX && screenPoint.x <= arView.bounds.maxX &&
             screenPoint.y >= arView.bounds.minY && screenPoint.y <= arView.bounds.maxY { // Point is within screen bounds
            visibleJointsDescriptions.append(jointName.rawValue.replacingOccurrences(of: "_joint", with: "").replacingOccurrences(of: "_", with: " ").capitalizedFirst())
          }
        }
      }
      let text = !visibleJointsDescriptions.isEmpty ? "Visible: " + visibleJointsDescriptions.prefix(5).joined(separator: ", ") + (visibleJointsDescriptions.count > 5 ? "..." : "") : (vm.detectedSubjectCount > 0 ? "Visible Parts: Subject Occluded/Out of View" : "Visible Parts: N/A")
      DispatchQueue.main.async {
        // Always update for fresh values
        self.vm.visibleBodyPartsInfo = text
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
          self.fetchInitialCameraFOV() // Re-fetch FOV as session restarted
        }
      } else { DispatchQueue.main.async { self.vm.bodyTrackingHint = "Session resumed, but config lost." } }
    }
    
    // Enhanced subject detection combining ARKit and Vision
    private func updateSubjectDetection(frame: ARFrame) {
        // Get ARKit body tracking bounds if available  
        var arSubjectBounds: SubjectBounds? = nil
        if let bodyAnchor = currentBodyAnchor, validateHumanBody(bodyAnchor) {
            arSubjectBounds = SubjectDetectionService.shared.calculateARSubjectBounds(from: bodyAnchor)
        } else if currentBodyAnchor != nil {
            // Clear invalid body anchor
            currentBodyAnchor = nil
            print("Cleared invalid body anchor in updateSubjectDetection")
        }
        
        // Perform Vision-based detection (throttled to avoid performance issues)
        if frame.timestamp.truncatingRemainder(dividingBy: 0.5) < 0.1 { // Run every ~0.5 seconds
            SubjectDetectionService.shared.detectHumanSubjects(
                in: frame.capturedImage,
                cameraTransform: frame.camera.transform
            ) { [weak self] visionBounds in
                guard let self = self else { return }
                
                // Combine ARKit and Vision data
                let hybridBounds = SubjectDetectionService.shared.hybridSubjectDetection(
                    arBounds: arSubjectBounds,
                    visionBounds: visionBounds
                )
                
                DispatchQueue.main.async {
                    self.vm.currentSubjectBounds = hybridBounds
                    
                    // Update guidance box if active and subject moved significantly
                    if let bounds = hybridBounds,
                       let activeGuidance = self.vm.activeGuidanceBox,
                       self.vm.isGuidanceActive {
                        
                        // Check if subject moved significantly (>10cm)
                        let movement = simd_distance(bounds.center, activeGuidance.targetPosition)
                        if movement > 0.1, let guidance = self.vm.latestStructuredGuidance {
                            // Update guidance box position
                            self.vm.activateGuidanceBox(for: guidance, subjectBounds: bounds)
                        }
                    }
                }
            }
        } else if let arBounds = arSubjectBounds {
            // Update with ARKit-only data when not running Vision
            DispatchQueue.main.async {
                self.vm.currentSubjectBounds = arBounds
            }
        }
    }
    
    private func syncBoxes(_ boxes: [PlacedBox]) { /* ... (Existing box syncing logic can be added here) ... */ }
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

// MARK: - 6 DOF Adjustment Models
struct DOFAdjustment: Codable {
    let translation: TranslationAdjustment
    let rotation: RotationAdjustment
}

struct TranslationAdjustment: Codable {
    let x: DirectionAdjustment  // Left/Right
    let y: DirectionAdjustment  // Up/Down
    let z: DirectionAdjustment  // Forward/Back
}

struct RotationAdjustment: Codable {
    let yaw: DirectionAdjustment   // Pan Left/Right
    let pitch: DirectionAdjustment // Tilt Up/Down
    let roll: DirectionAdjustment  // Rotate CW/CCW
}

struct DirectionAdjustment: Codable {
    let direction: String    // e.g., "left", "right", "up", "down", "forward", "back", "clockwise", "counter-clockwise", "no change"
    let magnitude: Double?   // Value in meters for translation or degrees for rotation
    let unit: String        // "m" for meters, "deg" for degrees
    let description: String // Human-readable description
}

struct StructuredGeminiResponse: Codable {
    let adjustments: DOFAdjustment
    let summary: String?
    let confidence: Double?
}

// MARK: - Subject Detection & Guidance Models
struct SubjectBounds {
    let center: SIMD3<Float>
    let size: SIMD3<Float>
    let confidence: Float
    let detectionSource: DetectionSource
}

enum DetectionSource {
    case arBodyTracking
    case visionFramework
    case hybrid
}

struct GuidanceBox {
    let id: UUID
    let targetPosition: SIMD3<Float>  // Keep for compatibility - will be calculated dynamically
    let subjectRelativeOffset: SIMD3<Float>  // Offset from subject center
    let size: SIMD3<Float>
    let confidence: Float
    let isActive: Bool
    let createdAt: Date
    
    // Calculate current world position based on subject position
    func currentWorldPosition(subjectCenter: SIMD3<Float>) -> SIMD3<Float> {
        return subjectCenter + subjectRelativeOffset
    }
}

// MARK: - Subject Detection Service
class SubjectDetectionService {
    static let shared = SubjectDetectionService()
    
    private let humanDetectionRequest: VNDetectHumanRectanglesRequest
    private let bodyPoseRequest: VNDetectHumanBodyPoseRequest
    
    private init() {
        humanDetectionRequest = VNDetectHumanRectanglesRequest()
        humanDetectionRequest.upperBodyOnly = false
        
        bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    }
    
    // Calculate subject bounds using ARKit body tracking
    func calculateARSubjectBounds(from bodyAnchor: ARBodyAnchor) -> SubjectBounds? {
        var jointPositions: [SIMD3<Float>] = []
        
        // Key joints for bounding box calculation (using correct ARKit joint names)
        let keyJoints: [ARSkeleton.JointName] = [
            .head,
            .leftShoulder, .rightShoulder,
            .leftHand, .rightHand,
            .leftFoot, .rightFoot,
            .root
        ]
        
        // Collect all available joint positions
        for jointName in keyJoints {
            if let jointTransform = bodyAnchor.skeleton.modelTransform(for: jointName) {
                let worldPosition = (bodyAnchor.transform * jointTransform).translation
                jointPositions.append(worldPosition)
            }
        }
        
        guard !jointPositions.isEmpty else { return nil }
        
        // Calculate 3D bounding box
        let minX = jointPositions.min(by: { $0.x < $1.x })?.x ?? 0
        let maxX = jointPositions.max(by: { $0.x < $1.x })?.x ?? 0
        let minY = jointPositions.min(by: { $0.y < $1.y })?.y ?? 0
        let maxY = jointPositions.max(by: { $0.y < $1.y })?.y ?? 0
        let minZ = jointPositions.min(by: { $0.z < $1.z })?.z ?? 0
        let maxZ = jointPositions.max(by: { $0.z < $1.z })?.z ?? 0
        
        // Add padding for human body volume (adaptive based on detected joints)
        let paddingFactor: Float = 0.4 // 40% padding to account for body volume beyond joints
        let width = (maxX - minX) * (1 + paddingFactor)
        let height = (maxY - minY) * (1 + paddingFactor)
        let depth = (maxZ - minZ) * (1 + paddingFactor)
        
        // Ensure minimum realistic human dimensions
        let minWidth: Float = 0.5  // 50cm minimum width
        let minHeight: Float = 1.4 // 140cm minimum height
        let minDepth: Float = 0.4  // 40cm minimum depth
        
        let finalWidth = max(width, minWidth)
        let finalHeight = max(height, minHeight)
        let finalDepth = max(depth, minDepth)
        
        let center = SIMD3<Float>(
            (minX + maxX) / 2,
            (minY + maxY) / 2,
            (minZ + maxZ) / 2
        )
        
        let size = SIMD3<Float>(finalWidth, finalHeight, finalDepth)
        
        // Calculate confidence based on number of visible joints
        let confidence = Float(jointPositions.count) / Float(keyJoints.count)
        
        return SubjectBounds(
            center: center,
            size: size,
            confidence: confidence,
            detectionSource: .arBodyTracking
        )
    }
    
    // Enhanced ML-based human detection using Vision framework
    func detectHumanSubjects(in pixelBuffer: CVPixelBuffer, cameraTransform: simd_float4x4, completion: @escaping ([SubjectBounds]) -> Void) {
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        
        let request = VNDetectHumanRectanglesRequest { [weak self] request, error in
            guard let self = self, error == nil else {
                completion([])
                return
            }
            
            var subjects: [SubjectBounds] = []
            
            if let observations = request.results as? [VNHumanObservation] {
                for observation in observations {
                    // Convert 2D bounding box to 3D estimate
                    if let subjectBounds = self.estimate3DBoundsFromVision(
                        observation: observation,
                        cameraTransform: cameraTransform
                    ) {
                        subjects.append(subjectBounds)
                    }
                }
            }
            
            completion(subjects)
        }
        request.upperBodyOnly = false
        
        do {
            try requestHandler.perform([request])
        } catch {
            print("Vision request failed: \(error)")
            completion([])
        }
    }
    
    private func estimate3DBoundsFromVision(observation: VNHumanObservation, cameraTransform: simd_float4x4) -> SubjectBounds? {
        // This is a simplified 3D estimation - in a real implementation, you'd use
        // depth information, camera intrinsics, and ML models for better accuracy
        
        let boundingBox = observation.boundingBox
        let confidence = observation.confidence
        
        // Estimate depth based on bounding box size (larger = closer)
        let estimatedDepth: Float = 2.0 / Float(boundingBox.height) // Rough heuristic
        
        // Convert normalized coordinates to world space (simplified)
        let centerX = Float(boundingBox.midX - 0.5) * estimatedDepth
        let centerY = Float(boundingBox.midY - 0.5) * estimatedDepth
        let centerZ = -estimatedDepth // Forward from camera
        
        // Transform to world coordinates
        let cameraSpacePosition = SIMD4<Float>(centerX, centerY, centerZ, 1.0)
        let worldPositionVec4 = cameraTransform * cameraSpacePosition
        let worldPosition = SIMD3<Float>(worldPositionVec4.x, worldPositionVec4.y, worldPositionVec4.z)
        
        // Estimate size based on typical human proportions
        let estimatedWidth = Float(boundingBox.width) * estimatedDepth * 0.8
        let estimatedHeight = Float(boundingBox.height) * estimatedDepth * 0.9
        let estimatedDepthSize: Float = 0.4 // Default human depth
        
        return SubjectBounds(
            center: worldPosition,
            size: SIMD3<Float>(estimatedWidth, estimatedHeight, estimatedDepthSize),
            confidence: confidence,
            detectionSource: .visionFramework
        )
    }
    
    // Combine ARKit and Vision detection for better accuracy
    func hybridSubjectDetection(arBounds: SubjectBounds?, visionBounds: [SubjectBounds]) -> SubjectBounds? {
        guard let arBounds = arBounds else {
            return visionBounds.first // Fall back to Vision if no ARKit data
        }
        
        if visionBounds.isEmpty {
            return arBounds // Use ARKit if no Vision data
        }
        
        // Find closest Vision detection to ARKit bounds
        let closestVision = visionBounds.min { bounds1, bounds2 in
            let dist1 = simd_distance(bounds1.center, arBounds.center)
            let dist2 = simd_distance(bounds2.center, arBounds.center)
            return dist1 < dist2
        }
        
        guard let vision = closestVision else { return arBounds }
        
        // Combine data - use ARKit position (more accurate) with Vision size refinement
        let hybridConfidence = (arBounds.confidence + vision.confidence) / 2
        
        // Weight the size based on confidence
        let arWeight = arBounds.confidence
        let visionWeight = vision.confidence
        let totalWeight = arWeight + visionWeight
        
        let hybridSize = SIMD3<Float>(
            (arBounds.size.x * arWeight + vision.size.x * visionWeight) / totalWeight,
            (arBounds.size.y * arWeight + vision.size.y * visionWeight) / totalWeight,
            (arBounds.size.z * arWeight + vision.size.z * visionWeight) / totalWeight
        )
        
        return SubjectBounds(
            center: arBounds.center, // Trust ARKit position more
            size: hybridSize,
            confidence: hybridConfidence,
            detectionSource: .hybrid
        )
    }
}

// SIMD4 extension for xyz access
extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        return SIMD3<Float>(x, y, z)
    }
}

// MARK: - Guidance Box Service
class GuidanceBoxService {
    static let shared = GuidanceBoxService()
    
    private init() {}
    
    // Calculate subject-relative offset instead of absolute world position
    func calculateSubjectRelativeOffset(
        currentSubjectBounds: SubjectBounds,
        recommendations: DOFAdjustment,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float> {
        
        // Use subject-relative vectors for positioning
        // This ensures the box follows the subject as they move
        let subjectRight = SIMD3<Float>(1.0, 0.0, 0.0)    // X-axis: left/right
        let subjectUp = SIMD3<Float>(0.0, 1.0, 0.0)       // Y-axis: up/down
        let subjectForward = SIMD3<Float>(0.0, 0.0, -1.0) // Z-axis: forward/back
        
        // Start with zero offset (box centered on subject)
        var relativeOffset = SIMD3<Float>(0, 0, 0)
        
        // Apply translation adjustments as offsets from subject center
        let translation = recommendations.translation
        
        // X-axis (left/right)
        if let xMagnitude = translation.x.magnitude, xMagnitude > 0 {
            let direction: Float = translation.x.direction == "right" ? 1.0 : -1.0
            relativeOffset += subjectRight * Float(xMagnitude) * direction
        }
        
        // Y-axis (up/down)
        if let yMagnitude = translation.y.magnitude, yMagnitude > 0 {
            let direction: Float = translation.y.direction == "up" ? 1.0 : -1.0
            relativeOffset += subjectUp * Float(yMagnitude) * direction
        }
        
        // Z-axis (forward/back)
        if let zMagnitude = translation.z.magnitude, zMagnitude > 0 {
            let direction: Float = translation.z.direction == "forward" ? 1.0 : -1.0
            relativeOffset += subjectForward * Float(zMagnitude) * direction
        }
        
        return relativeOffset
    }
    
    // Create guidance box with adaptive sizing and subject-relative offset
    func createGuidanceBox(
        relativeOffset: SIMD3<Float>,
        subjectBounds: SubjectBounds,
        recommendations: DOFAdjustment
    ) -> GuidanceBox {
        
        // Use subject bounds size with generous expansion to ensure it fits the subject
        let expansionFactor: Float = 1.3 // 30% larger to ensure subject fits comfortably
        let guidanceSize = subjectBounds.size * expansionFactor
        
        // Ensure minimum realistic human dimensions for visibility
        let minWidth: Float = 0.6   // 60cm minimum width
        let minHeight: Float = 1.5  // 150cm minimum height  
        let minDepth: Float = 0.5   // 50cm minimum depth
        
        let finalSize = SIMD3<Float>(
            max(guidanceSize.x, minWidth),
            max(guidanceSize.y, minHeight),
            max(guidanceSize.z, minDepth)
        )
        
        // Calculate initial target position for compatibility
        let initialTargetPosition = subjectBounds.center + relativeOffset
        
        return GuidanceBox(
            id: UUID(),
            targetPosition: initialTargetPosition,
            subjectRelativeOffset: relativeOffset,
            size: finalSize,
            confidence: subjectBounds.confidence,
            isActive: true,
            createdAt: Date()
        )
    }
}

// MARK: - RealityKit Guidance Visualization
class GuidanceBoxRenderer {
    static let shared = GuidanceBoxRenderer()
    
    private var guidanceAnchor: AnchorEntity?
    private var boxEntity: ModelEntity?
    private var currentGuidanceBox: GuidanceBox?
    
    private init() {}
    
    func createGuidanceBoxEntity(guidanceBox: GuidanceBox) -> ModelEntity {
        // Create wireframe box mesh
        let size = guidanceBox.size
        
        // Create box mesh with wireframe material
        let boxMesh = MeshResource.generateBox(
            width: size.x,
            height: size.y,
            depth: size.z
        )
        
        // Create semi-transparent green material for better visibility
        var transparentMaterial = UnlitMaterial(color: UIColor(red: 0, green: 1, blue: 0, alpha: 0.2))
        transparentMaterial.blending = .transparent(opacity: 0.2)
        
        // Create main box with semi-transparent material
        let boxEntity = ModelEntity(mesh: boxMesh, materials: [transparentMaterial])
        
        // Create wireframe edges manually for better visibility (also semi-transparent)
        let wireframeThickness: Float = 0.03 // Increased thickness for better visibility
        let edgeColor = UIColor(red: 0, green: 1, blue: 0, alpha: 0.8) // Semi-transparent bright green
        
        // Create 12 edge lines for the box wireframe
        let edges = createWireframeEdges(size: size, thickness: wireframeThickness, color: edgeColor)
        for edge in edges {
            boxEntity.addChild(edge)
        }
        
        return boxEntity
    }
    
    private func createWireframeEdges(size: SIMD3<Float>, thickness: Float, color: UIColor) -> [ModelEntity] {
        var edges: [ModelEntity] = []
        var material = UnlitMaterial(color: color)
        if color.cgColor.alpha < 1.0 {
            material.blending = .transparent(opacity: .init(floatLiteral: Float(color.cgColor.alpha)))
        }
        
        let halfWidth = size.x / 2
        let halfHeight = size.y / 2
        let halfDepth = size.z / 2
        
        // Define the 8 corners of the box
        let corners: [SIMD3<Float>] = [
            SIMD3(-halfWidth, -halfHeight, -halfDepth), // 0: bottom-front-left
            SIMD3( halfWidth, -halfHeight, -halfDepth), // 1: bottom-front-right
            SIMD3( halfWidth,  halfHeight, -halfDepth), // 2: top-front-right
            SIMD3(-halfWidth,  halfHeight, -halfDepth), // 3: top-front-left
            SIMD3(-halfWidth, -halfHeight,  halfDepth), // 4: bottom-back-left
            SIMD3( halfWidth, -halfHeight,  halfDepth), // 5: bottom-back-right
            SIMD3( halfWidth,  halfHeight,  halfDepth), // 6: top-back-right
            SIMD3(-halfWidth,  halfHeight,  halfDepth)  // 7: top-back-left
        ]
        
        // Define the 12 edges of the box (connecting corners)
        let edgeConnections: [(Int, Int)] = [
            // Bottom face (y = -halfHeight)
            (0, 1), (1, 5), (5, 4), (4, 0),
            // Top face (y = +halfHeight)
            (3, 2), (2, 6), (6, 7), (7, 3),
            // Vertical edges
            (0, 3), (1, 2), (5, 6), (4, 7)
        ]
        
        // Create edge lines
        for (start, end) in edgeConnections {
            let startPos = corners[start]
            let endPos = corners[end]
            let center = (startPos + endPos) / 2
            
            // Calculate edge dimensions
            let dx = abs(endPos.x - startPos.x)
            let dy = abs(endPos.y - startPos.y)
            let dz = abs(endPos.z - startPos.z)
            
            // Create edge mesh with appropriate dimensions
            let edgeMesh: MeshResource
            if dx > 0.01 { // Horizontal edge along X
                edgeMesh = MeshResource.generateBox(width: dx, height: thickness, depth: thickness)
            } else if dy > 0.01 { // Vertical edge along Y
                edgeMesh = MeshResource.generateBox(width: thickness, height: dy, depth: thickness)
            } else { // Edge along Z
                edgeMesh = MeshResource.generateBox(width: thickness, height: thickness, depth: dz)
            }
            
            let edgeEntity = ModelEntity(mesh: edgeMesh, materials: [material])
            edgeEntity.position = center
            
            edges.append(edgeEntity)
        }
        
        return edges
    }
    
    func showGuidanceBox(_ guidanceBox: GuidanceBox, in arView: ARView) {
        print("🎯 GuidanceBoxRenderer.showGuidanceBox called")
        print("   Target Position: \(guidanceBox.targetPosition)")
        print("   Relative Offset: \(guidanceBox.subjectRelativeOffset)")
        print("   Size: \(guidanceBox.size)")
        
        // Store current guidance box for position updates
        currentGuidanceBox = guidanceBox
        
        // Remove existing guidance
        hideGuidanceBox(in: arView)
        
        // Create new guidance anchor at initial position
        guidanceAnchor = AnchorEntity(world: guidanceBox.targetPosition)
        print("   ✅ Created anchor at world position: \(guidanceBox.targetPosition)")
        
        // Create box entity
        boxEntity = createGuidanceBoxEntity(guidanceBox: guidanceBox)
        print("   ✅ Created box entity")
        
        if let anchor = guidanceAnchor, let entity = boxEntity {
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
            print("   ✅ Added box to AR scene")
            
            // Add subtle scale for visibility
            entity.transform.scale = SIMD3<Float>(1.0, 1.0, 1.0)
            
            // Verify anchor is in scene
            if arView.scene.anchors.contains(where: { $0 === anchor }) {
                print("   ✅ Confirmed: Anchor is in AR scene")
            } else {
                print("   ❌ Error: Anchor not found in AR scene after adding")
            }
        } else {
            print("   ❌ Error: Failed to create anchor or entity")
        }
    }
    
    func hideGuidanceBox(in arView: ARView) {
        if let anchor = guidanceAnchor {
            arView.scene.removeAnchor(anchor)
            guidanceAnchor = nil
            boxEntity = nil
            currentGuidanceBox = nil
        }
    }
    
    func updateGuidanceBox(_ guidanceBox: GuidanceBox, in arView: ARView) {
        guard let anchor = guidanceAnchor, let entity = boxEntity else {
            // No existing guidance, create new one
            showGuidanceBox(guidanceBox, in: arView)
            return
        }
        
        // Update position smoothly
        let currentTransform = anchor.transform
        let targetTransform = Transform(
            scale: currentTransform.scale,
            rotation: currentTransform.rotation,
            translation: guidanceBox.targetPosition
        )
        
        // Animate to new position
        anchor.move(to: targetTransform, relativeTo: nil, duration: 0.5)
    }
    
    // Update box position based on current subject position
    func updateBoxPositionForSubject(subjectBounds: SubjectBounds, in arView: ARView) {
        guard let guidanceBox = currentGuidanceBox,
              let anchor = guidanceAnchor else {
            return
        }
        
        // Calculate new world position based on current subject center and stored offset
        let newWorldPosition = guidanceBox.currentWorldPosition(subjectCenter: subjectBounds.center)
        
        // Update position smoothly
        let currentTransform = anchor.transform
        let targetTransform = Transform(
            scale: currentTransform.scale,
            rotation: currentTransform.rotation,
            translation: newWorldPosition
        )
        
        // Animate to new position (faster animation for real-time tracking)
        anchor.move(to: targetTransform, relativeTo: nil, duration: 0.2)
    }
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
           // CORRECTED SECTION TO AVOID OVERLAPPING ACCESS
           if var components = URLComponents(string: apiURL) { // Make components mutable
               var currentQueryItems = components.queryItems ?? []
               currentQueryItems.append(URLQueryItem(name: "key", value: apiKey))
               components.queryItems = currentQueryItems
               
               if let urlWithKey = components.url?.absoluteString {
                   self.flashApiURLString = urlWithKey
                   print("APIService (Flash Gen) configured. URL (appended key): \(self.flashApiURLString)")
               } else {
                   self.flashApiURLString = apiURL // Fallback if URL construction fails after modification
                   print("APIService (Flash Gen) configured. API Key provided, but FAILED to construct final URL. Using original URL: \(apiURL)")
               }
           } else {
               self.flashApiURLString = apiURL // Fallback if initial URLComponents creation fails
               print("APIService (Flash Gen) configured. API Key provided, but FAILED to parse initial URL. Using original URL: \(apiURL)")
           }
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
        let errorDetail = String(data: data, encoding: .utf8) ?? "No error details"
        throw NSError(domain: "APIService.Analysis", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response. Status: \((response as? HTTPURLResponse)?.statusCode ?? -1). Detail: \(errorDetail)"])
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
    let requestBody: [String: Any] = [
        "contents": [
            ["parts": [["text": prompt]]]
        ],
    ]
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
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
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
    
    let requestPayload: [String: Any] = [
        "contents": [["parts": partsArray]]
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
    print("Sending multimodal request to Flash Gen API: \(url.absoluteString). Prompt length: \(prompt.count) chars. Ref Img: \(base64RefImage.count/1024)KB, Cur Img: \(base64CurrentImage.count/1024)KB")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(domain: "APIService.FlashGen", code: 104, userInfo: [NSLocalizedDescriptionKey: "Invalid response object."])
    }
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
                    directivesText = text
                    break
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
  
  func sendStructuredImageComparisonRequest(referenceImage: UIImage, currentImage: UIImage, prompt: String, additionalMetrics: [String: String]?) async throws -> (StructuredGeminiResponse, String) {
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
    
    let requestPayload: [String: Any] = [
        "contents": [["parts": partsArray]]
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
    print("Sending structured multimodal request to Flash Gen API: \(url.absoluteString). Prompt length: \(prompt.count) chars. Ref Img: \(base64RefImage.count/1024)KB, Cur Img: \(base64CurrentImage.count/1024)KB")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(domain: "APIService.FlashGen", code: 104, userInfo: [NSLocalizedDescriptionKey: "Invalid response object."])
    }
    print("Flash Gen API (Structured) Status Code: \(httpResponse.statusCode)")
    
    guard (200...299).contains(httpResponse.statusCode) else {
        let errorDetail = String(data: data, encoding: .utf8) ?? "No details"
        print("Flash API Error (\(httpResponse.statusCode)): \(errorDetail)")
        throw NSError(domain: "APIService.FlashGen", code: 105, userInfo: [NSLocalizedDescriptionKey: "Flash API error. Status: \(httpResponse.statusCode). Details: \(errorDetail.prefix(500))"])
    }
    
    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw NSError(domain: "APIService.FlashGen", code: 107, userInfo: [NSLocalizedDescriptionKey: "Response not valid JSON structure."])
        }
        
        var jsonResponseText = ""
        for part in parts {
            if let text = part["text"] as? String {
                jsonResponseText = text
                break
            }
        }
        
        // Clean the response text (remove any markdown formatting if present)
        let cleanedJSON = jsonResponseText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse the JSON response into our structured model
        guard let jsonData = cleanedJSON.data(using: .utf8) else {
            throw NSError(domain: "APIService.FlashGen", code: 108, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response text to data."])
        }
        
        let structuredResponse = try JSONDecoder().decode(StructuredGeminiResponse.self, from: jsonData)
        
        print("Successfully parsed structured response from Gemini")
        return (structuredResponse, jsonResponseText)
        
    } catch let decodingError as DecodingError {
        let rawResponse = String(data: data, encoding: .utf8) ?? "No raw data"
        print("Failed to decode structured response: \(decodingError). Raw: \(rawResponse.prefix(500))")
        throw NSError(domain: "APIService.FlashGen", code: 109, userInfo: [NSLocalizedDescriptionKey: "Failed to decode structured response: \(decodingError.localizedDescription)"])
    } catch {
        throw error
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
  private let userDefaultsKey = "savedPolarisOneResponses_v2"
  func loadResponsesAsync() async {
    await MainActor.run {
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

// MARK: - Settings View
struct SettingsView: View {
  @ObservedObject var viewModel: ARViewModel
  @Environment(\.dismiss) var dismiss
  
  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Display Options")) {
          Toggle("Show Detailed Metrics", isOn: $viewModel.showDetailedMetrics)
            .toggleStyle(SwitchToggleStyle())
          
          Text("When disabled, hides all metrics except the AR tracking hint")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        
        Section(header: Text("3D Export")) {
          Button(action: {
            if !viewModel.isBodyTrackingActive {
              viewModel.shareURL = ARMeshExporter.exportCurrentScene()
            }
          }) {
            HStack {
              Image(systemName: "cube.box")
                .foregroundColor(.accentColor)
              Text("Export 3D Scene")
                .foregroundColor(.primary)
              Spacer()
              if viewModel.isBodyTrackingActive || !ARMeshExporter.hasMesh {
                Text("Unavailable")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
          .disabled(viewModel.isBodyTrackingActive || !ARMeshExporter.hasMesh)
          
          Text("Export the current AR scene as a USDZ file. Only available with LiDAR devices when body tracking is disabled.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        
        Section(header: Text("About")) {
          HStack {
            Text("Version")
            Spacer()
            Text("1.0.0")
              .foregroundColor(.secondary)
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Reference Image Handling (Model, Manager, ViewModel, Picker, Selector)
struct ReferenceImageMetadata: Codable, Equatable {
    var distanceFromCamera: String
    var distanceBelowEyeline: String
    var cameraHeight: String
    // New comprehensive metrics
    var cameraHeightRelativeToEyes: String
    var visibleBodyParts: String
    var detectedSubjectCount: String
    var cameraRollDeg: String
    var cameraPitchDeg: String
    var cameraYawDeg: String
    var cameraFOVHDeg: String
    var ambientLux: String
    var colorTempK: String
    var captureDate: Date
    
    static var empty: ReferenceImageMetadata { 
        ReferenceImageMetadata(
            distanceFromCamera: "", 
            distanceBelowEyeline: "", 
            cameraHeight: "",
            cameraHeightRelativeToEyes: "",
            visibleBodyParts: "",
            detectedSubjectCount: "",
            cameraRollDeg: "",
            cameraPitchDeg: "",
            cameraYawDeg: "",
            cameraFOVHDeg: "",
            ambientLux: "",
            colorTempK: "",
            captureDate: Date()
        ) 
    }
}

struct ReferenceImage: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let dateAdded: Date
    var metadata: ReferenceImageMetadata
    
    var image: UIImage? {
        let imageUrl = ReferenceImageManager.shared.url(for: filename)
        return UIImage(contentsOfFile: imageUrl.path)
    }
    
    static func == (lhs: ReferenceImage, rhs: ReferenceImage) -> Bool {
        lhs.id == rhs.id && lhs.filename == rhs.filename
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, dateAdded, metadata
    }
}

class ReferenceImageManager {
    static let shared = ReferenceImageManager()
    private let key = "referenceImages_v3"
    private let folder = "ReferenceImages"
    private var folderURL: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(folder)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }
    func url(for filename: String) -> URL { folderURL.appendingPathComponent(filename) }
    
    func saveImage(_ image: UIImage, metadata: ReferenceImageMetadata) -> ReferenceImage? {
        let id = UUID(); let filename = "refimg_\(id.uuidString).jpg"; let fileUrl = self.url(for: filename)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: fileUrl)
            let ref = ReferenceImage(id: id, filename: filename, dateAdded: Date(), metadata: metadata)
            var refs = loadImages(); refs.append(ref); saveImagesMetadata(refs); return ref
        } catch { print("Failed to save ref image: \(error)"); return nil }
    }
    
    func loadImages() -> [ReferenceImage] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([ReferenceImage].self, from: data)
        } catch {
            print("Failed to decode reference images metadata: \(error)")
            return []
        }
    }
    
    func saveImagesMetadata(_ refs: [ReferenceImage]) {
        do {
            let data = try JSONEncoder().encode(refs)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("Failed to encode reference images metadata: \(error)")
        }
    }
    
    func deleteImage(_ ref: ReferenceImage) {
        try? FileManager.default.removeItem(at: url(for: ref.filename))
        saveImagesMetadata(loadImages().filter { $0.id != ref.id })
    }
}

class ReferenceImageViewModel: ObservableObject {
    @Published var images: [ReferenceImage] = []
    @Published var selected: ReferenceImage?
    @Published var showPicker = false
    @Published var showSelector = false
    @Published var showMetadataInput = false
    @Published var pendingImage: UIImage? = nil
    @Published var metadataInput = ReferenceImageMetadata.empty
    
    private let selectedKey = "selectedRefImg_v3"

    init() {
        load()
        loadSelection()
        
        // Listen for capture notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshImages),
            name: Notification.Name("RefreshReferenceImages"),
            object: nil
        )
    }
    
    @objc private func refreshImages() {
        load()
    }
    
    func load() {
        images = ReferenceImageManager.shared.loadImages().sorted(by: { $0.dateAdded > $1.dateAdded })
        if let selId = selected?.id, !images.contains(where: { $0.id == selId }) {
            selected = images.first
            saveSelection()
        } else if selected == nil && !images.isEmpty {
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
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 60, height: 60).cornerRadius(8)
                                .overlay(Image(systemName: "photo").foregroundColor(.white))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Added: \(ref.dateAdded, formatter: dateFormatter)").font(.caption)
                            if vm.selected == ref {
                                Text("SELECTED").font(.caption2).bold().foregroundColor(.accentColor)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Dist: \(ref.metadata.distanceFromCamera.isEmpty ? "N/A" : ref.metadata.distanceFromCamera)m").font(.caption2)
                                Text("Height: \(ref.metadata.cameraHeight.isEmpty ? "N/A" : ref.metadata.cameraHeight)m").font(.caption2)
                                Text("Subjects: \(ref.metadata.detectedSubjectCount.isEmpty ? "N/A" : ref.metadata.detectedSubjectCount)").font(.caption2)
                                if !ref.metadata.cameraRollDeg.isEmpty && ref.metadata.cameraRollDeg != "N/A" {
                                    Text("Angle: R:\(ref.metadata.cameraRollDeg)° P:\(ref.metadata.cameraPitchDeg)°").font(.caption2)
                                }
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
                    TextField("Subject distance from camera (m)", text: $distanceFromCamera)
                        .keyboardType(.decimalPad)
                    TextField("Camera height from floor (m)", text: $cameraHeight)
                        .keyboardType(.decimalPad)
                }
                 Text("Add any manual adjustments to the metadata if needed. Note: Photos captured with the camera button will have all metrics automatically recorded.")
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
                        // Create metadata with manual values, leave other fields empty
                        let meta = ReferenceImageMetadata(
                            distanceFromCamera: distanceFromCamera,
                            distanceBelowEyeline: distanceBelowEyeline,
                            cameraHeight: cameraHeight,
                            cameraHeightRelativeToEyes: "",
                            visibleBodyParts: "",
                            detectedSubjectCount: "",
                            cameraRollDeg: "",
                            cameraPitchDeg: "",
                            cameraYawDeg: "",
                            cameraFOVHDeg: "",
                            ambientLux: "",
                            colorTempK: "",
                            captureDate: Date()
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
        let angle = acos(min(max(dot(nFrom, nTo), -1.0), 1.0))
        if simd_length_squared(axis) < 0.0001*0.0001 {
            self = simd_quatf(angle: dot(nFrom, nTo) > 0 ? 0 : .pi, axis: simd_float3(0,1,0))
        } else {
            self = simd_quatf(angle: angle, axis: normalize(axis))
        }
    }
}

// MARK: - SIMD3 Arithmetic Extensions
extension SIMD3 where Scalar == Float {
    static func +(lhs: SIMD3<Float>, rhs: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
    
    static func -(lhs: SIMD3<Float>, rhs: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }
    
    static func *(lhs: SIMD3<Float>, rhs: Float) -> SIMD3<Float> {
        return SIMD3<Float>(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
    
    static func +=(lhs: inout SIMD3<Float>, rhs: SIMD3<Float>) {
        lhs = lhs + rhs
    }
    
    static func -=(lhs: inout SIMD3<Float>, rhs: SIMD3<Float>) {
        lhs = lhs - rhs
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
