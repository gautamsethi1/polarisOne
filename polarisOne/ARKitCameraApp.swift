//  polarisOne
/*
 ARKitCameraApp.swift – Self‑contained SwiftUI + RealityKit demo
 -----------------------------------------------------------------
 • Live plane & mesh visualisation
 • Body detection with distance calculation
 • One‑tap USDZ export via share‑sheet (LiDAR only)
 • Integrated call to Flash 2.5 Generation Model
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
import CoreMotion // For device motion (Apple-style levels)

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

// MARK: - Potential File: Views/ContentView.swift
// MARK: – Root SwiftUI view
struct ContentView: View {
  @StateObject private var vm = ARViewModel()
  @StateObject private var refVM = ReferenceImageViewModel()
  @StateObject private var boxVM = BoxPlacementViewModel()

  var body: some View {
    ZStack(alignment: .topLeading) {
      ARViewContainer(viewModel: vm, boxVM: boxVM).ignoresSafeArea()
      
      // Add 2D guidance overlay
      GuidanceOverlay(viewModel: vm)
        .ignoresSafeArea()

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
          Text(vm.subjectRelativeOrientationString).infoStyle(fontSize: .caption2)
          Text(vm.fieldOfViewDegString).infoStyle(fontSize: .caption2)
          Text(vm.ambientLuxString).infoStyle(fontSize: .caption2)
          Text(vm.colorTempKString).infoStyle(fontSize: .caption2)
        }
        
        // Show alignment score when guidance is active
        if vm.isGuidanceActive && vm.guidanceAlignmentScore > 0 {
          HStack {
            Circle()
              .fill(vm.guidanceAlignmentScore > 0.8 ? Color.green : 
                    vm.guidanceAlignmentScore > 0.5 ? Color.yellow : Color.red)
              .frame(width: 8, height: 8)
            Text("Stability: \(Int(vm.guidanceAlignmentScore * 100))%")
              .font(.caption)
              .fontWeight(.semibold)
          }
          .padding(.vertical, 4)
          .padding(.horizontal, 10)
          .background(.ultraThinMaterial)
          .cornerRadius(16)
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
    let framing: FramingGuidance?
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
}

extension DirectionAdjustment {
    var description: String {
        if direction.lowercased() == "no change" {
            return "No change"
        }
        
        guard let magnitude = magnitude, magnitude > 0 else {
            return "No change"
        }
        
        return "\(direction) \(String(format: "%.1f", magnitude))\(unit)"
    }
}

struct StructuredGeminiResponse: Codable {
    let adjustments: DOFAdjustment
    let summary: String?
    let confidence: Double?
}

struct FramingGuidance: Codable {
    let subject_position: String?  // "center", "left_third", "right_third", etc.
    let composition_rule: String?  // "rule_of_thirds", "golden_ratio", etc.
    let framing_type: String?      // "close_up", "medium_shot", "full_body", etc.
    let ideal_subject_percentage: Double?  // 0.0-1.0 how much of frame subject should fill
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

// 2D Guidance directions for overlay
struct GuidanceDirections {
    var moveLeft: Float = 0
    var moveRight: Float = 0
    var moveUp: Float = 0
    var moveDown: Float = 0
    var moveForward: Float = 0
    var moveBack: Float = 0
    var turnLeft: Float = 0
    var turnRight: Float = 0
    var tiltUp: Float = 0
    var tiltDown: Float = 0
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
        let paddingFactor: Float = 0.15 // 15% padding to account for body volume beyond joints
        let width = (maxX - minX) * (1 + paddingFactor)
        let height = (maxY - minY) * (1 + paddingFactor)
        let depth = (maxZ - minZ) * (1 + paddingFactor)
        
        // Ensure minimum realistic human dimensions
        let minWidth: Float = 0.3  // 30cm minimum width
        let minHeight: Float = 0.8 // 80cm minimum height (for seated persons)
        let minDepth: Float = 0.3  // 30cm minimum depth
        
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
    
    // Calculate optimal framing box position based on subject and LLM recommendations
    func calculateOptimalFramingPosition(
        currentSubjectBounds: SubjectBounds,
        recommendations: DOFAdjustment,
        cameraTransform: simd_float4x4
    ) -> (position: SIMD3<Float>, distance: Float) {
        
        // Get camera vectors and position
        let cameraRight = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let cameraUp = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
        let cameraForward = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // The guidance box should show where the subject SHOULD BE in the world
        // based on the AI recommendations. The user then moves their camera
        // to align the real subject with this target position.
        
        var targetSubjectPosition = currentSubjectBounds.center
        let currentDistance = simd_length(currentSubjectBounds.center - cameraPosition)
        var targetDistance = currentDistance
        
        // Process AI recommendations - these tell us how the CAMERA should move
        // So we invert them to show where the subject should appear
        let translation = recommendations.translation
        
        // X-axis: If camera should move right, subject appears left in frame
        if let xMagnitude = translation.x.magnitude, xMagnitude > 0 {
            let direction: Float = translation.x.direction == "right" ? -1.0 : 1.0
            targetSubjectPosition += cameraRight * Float(xMagnitude) * direction
        }
        
        // Y-axis: If camera should move up, subject appears lower in frame
        if let yMagnitude = translation.y.magnitude, yMagnitude > 0 {
            let direction: Float = translation.y.direction == "up" ? -1.0 : 1.0
            targetSubjectPosition += cameraUp * Float(yMagnitude) * direction
        }
        
        // Z-axis: Adjust target distance
        if let zMagnitude = translation.z.magnitude, zMagnitude > 0 {
            if translation.z.direction == "forward" {
                targetDistance -= Float(zMagnitude)
            } else if translation.z.direction == "back" {
                targetDistance += Float(zMagnitude)
            }
        }
        
        return (targetSubjectPosition, targetDistance)
    }
    
    // Create guidance box that frames the subject optimally
    func createGuidanceBox(
        targetPosition: SIMD3<Float>,
        targetDistance: Float,
        subjectBounds: SubjectBounds,
        recommendations: DOFAdjustment,
        cameraTransform: simd_float4x4
    ) -> GuidanceBox {
        
        // Get camera intrinsics for proper framing calculation
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Calculate the frame size based on how the subject should appear in camera view
        // This represents the "window" through which we want to see the subject
        
        // Start with the actual subject size
        let subjectWidth = subjectBounds.size.x
        let subjectHeight = subjectBounds.size.y
        
        // Determine desired framing based on AI recommendations
        var framingMultiplier: Float = 1.5  // Default: subject fills 67% of frame
        
        if let framing = recommendations.framing {
            // Adjust based on framing type
            switch framing.framing_type {
            case "close_up":
                framingMultiplier = 1.1  // Subject fills 91% of frame
            case "medium_shot":
                framingMultiplier = 1.5  // Subject fills 67% of frame
            case "full_body":
                framingMultiplier = 2.0  // Subject fills 50% of frame
            case "environmental":
                framingMultiplier = 3.0  // Subject fills 33% of frame
            default:
                framingMultiplier = 1.5
            }
            
            // Override with specific percentage if provided
            if let idealPercentage = framing.ideal_subject_percentage, idealPercentage > 0 {
                framingMultiplier = 1.0 / Float(idealPercentage)
            }
        }
        
        // Calculate the guidance frame size
        // This represents how big the framing window should be
        let frameHeight = subjectHeight * framingMultiplier
        let frameWidth = subjectWidth * framingMultiplier * 1.5  // Wider aspect for better composition
        
        // The frame size should NOT change with distance - it represents
        // the desired framing, not a physical object
        let finalSize = SIMD3<Float>(
            frameWidth,
            frameHeight,
            0.02  // Very thin frame
        )
        
        return GuidanceBox(
            id: UUID(),
            targetPosition: targetPosition,
            subjectRelativeOffset: targetPosition - subjectBounds.center,
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
    private var lastAlignmentQuality: Float = 0.0
    
    private init() {}
    
    func createGuidanceBoxEntity(guidanceBox: GuidanceBox, alignmentQuality: Float = 0.0) -> ModelEntity {
        // Create 2D rectangular frame with composition guides
        let size = guidanceBox.size
        
        // Create empty parent entity
        let frameEntity = ModelEntity()
        
        // Calculate color based on alignment quality (red -> yellow -> green)
        let edgeColor: UIColor
        if alignmentQuality < 0.3 {
            // Poor alignment - red
            edgeColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1.0)
        } else if alignmentQuality < 0.7 {
            // Medium alignment - yellow
            let greenAmount = (alignmentQuality - 0.3) / 0.4
            edgeColor = UIColor(red: 1, green: CGFloat(greenAmount), blue: 0, alpha: 1.0)
        } else {
            // Good alignment - green
            let redAmount = 1.0 - (alignmentQuality - 0.7) / 0.3
            edgeColor = UIColor(red: CGFloat(redAmount), green: 1, blue: 0, alpha: 1.0)
        }
        
        // Main frame edges
        let wireframeThickness: Float = 0.08
        
        // Create main frame edges
        let edges = create2DFrameEdges(size: size, thickness: wireframeThickness, color: edgeColor)
        for edge in edges {
            frameEntity.addChild(edge)
        }
        
        // Add rule of thirds guidelines (thinner and semi-transparent)
        let guideThickness: Float = 0.02
        let guideAlpha = 0.3 + (alignmentQuality * 0.3)  // More visible when better aligned
        let guideColor = UIColor(red: 0, green: 1, blue: 0, alpha: CGFloat(guideAlpha))
        let thirds = createRuleOfThirdsGuides(size: size, thickness: guideThickness, color: guideColor)
        for guide in thirds {
            frameEntity.addChild(guide)
        }
        
        return frameEntity
    }
    
    private func create2DFrameEdges(size: SIMD3<Float>, thickness: Float, color: UIColor) -> [ModelEntity] {
        var edges: [ModelEntity] = []
        // Use SimpleMaterial for better visibility
        let material = SimpleMaterial(color: color, isMetallic: false)
        
        let halfWidth = size.x / 2
        let halfHeight = size.y / 2
        
        // Create thicker, more visible edges
        let edgeThickness: Float = 0.05 // 5cm thick for better visibility
        
        // Top edge
        let topEdge = ModelEntity(mesh: MeshResource.generateBox(width: size.x, height: edgeThickness, depth: edgeThickness), materials: [material])
        topEdge.position = SIMD3<Float>(0, halfHeight, 0)
        edges.append(topEdge)
        
        // Bottom edge
        let bottomEdge = ModelEntity(mesh: MeshResource.generateBox(width: size.x, height: edgeThickness, depth: edgeThickness), materials: [material])
        bottomEdge.position = SIMD3<Float>(0, -halfHeight, 0)
        edges.append(bottomEdge)
        
        // Left edge
        let leftEdge = ModelEntity(mesh: MeshResource.generateBox(width: edgeThickness, height: size.y, depth: edgeThickness), materials: [material])
        leftEdge.position = SIMD3<Float>(-halfWidth, 0, 0)
        edges.append(leftEdge)
        
        // Right edge
        let rightEdge = ModelEntity(mesh: MeshResource.generateBox(width: edgeThickness, height: size.y, depth: edgeThickness), materials: [material])
        rightEdge.position = SIMD3<Float>(halfWidth, 0, 0)
        edges.append(rightEdge)
        
        // Add corner spheres for better visibility
        let cornerRadius: Float = edgeThickness * 1.5
        let cornerMaterial = SimpleMaterial(color: color, isMetallic: false)
        
        // Create 4 corner spheres
        let corners = [
            SIMD3<Float>(-halfWidth, -halfHeight, 0), // bottom-left
            SIMD3<Float>( halfWidth, -halfHeight, 0), // bottom-right
            SIMD3<Float>( halfWidth,  halfHeight, 0), // top-right
            SIMD3<Float>(-halfWidth,  halfHeight, 0)  // top-left
        ]
        
        for corner in corners {
            let cornerSphere = ModelEntity(mesh: MeshResource.generateSphere(radius: cornerRadius), materials: [cornerMaterial])
            cornerSphere.position = corner
            edges.append(cornerSphere)
        }
        
        return edges
    }
    
    private func createRuleOfThirdsGuides(size: SIMD3<Float>, thickness: Float, color: UIColor) -> [ModelEntity] {
        var guides: [ModelEntity] = []
        let material = SimpleMaterial(color: color, isMetallic: false)
        
        let halfWidth = size.x / 2
        let halfHeight = size.y / 2
        let thirdWidth = size.x / 3
        let thirdHeight = size.y / 3
        
        // Vertical guides at 1/3 and 2/3
        let leftGuide = ModelEntity(mesh: MeshResource.generateBox(width: thickness, height: size.y, depth: thickness), materials: [material])
        leftGuide.position = SIMD3<Float>(-thirdWidth / 2, 0, 0)
        guides.append(leftGuide)
        
        let rightGuide = ModelEntity(mesh: MeshResource.generateBox(width: thickness, height: size.y, depth: thickness), materials: [material])
        rightGuide.position = SIMD3<Float>(thirdWidth / 2, 0, 0)
        guides.append(rightGuide)
        
        // Horizontal guides at 1/3 and 2/3
        let topGuide = ModelEntity(mesh: MeshResource.generateBox(width: size.x, height: thickness, depth: thickness), materials: [material])
        topGuide.position = SIMD3<Float>(0, thirdHeight / 2, 0)
        guides.append(topGuide)
        
        let bottomGuide = ModelEntity(mesh: MeshResource.generateBox(width: size.x, height: thickness, depth: thickness), materials: [material])
        bottomGuide.position = SIMD3<Float>(0, -thirdHeight / 2, 0)
        guides.append(bottomGuide)
        
        return guides
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
        print("   Size: \(guidanceBox.size)")
        
        // Store current guidance box for position updates
        currentGuidanceBox = guidanceBox
        
        // Remove existing guidance
        hideGuidanceBox(in: arView)
        
        // Get camera transform for orientation
        guard let frame = arView.session.currentFrame else {
            print("   ❌ No current AR frame available")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Create new guidance anchor at the target position
        guidanceAnchor = AnchorEntity(world: guidanceBox.targetPosition)
        print("   ✅ Created anchor at position: \(guidanceBox.targetPosition)")
        
        // Create box entity
        boxEntity = createGuidanceBoxEntity(guidanceBox: guidanceBox)
        print("   ✅ Created framing box entity")
        
        if let anchor = guidanceAnchor, let entity = boxEntity {
            // Calculate rotation to face the camera (billboard effect)
            let direction = normalize(cameraPosition - guidanceBox.targetPosition)
            
            // Create a look-at rotation
            // We want the frame to face the camera, so the forward vector points toward camera
            let up = SIMD3<Float>(0, 1, 0)  // World up
            let right = normalize(cross(up, direction))
            let adjustedUp = cross(direction, right)
            
            // Create rotation matrix
            var rotationMatrix = simd_float4x4()
            rotationMatrix.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
            rotationMatrix.columns.1 = SIMD4<Float>(adjustedUp.x, adjustedUp.y, adjustedUp.z, 0)
            rotationMatrix.columns.2 = SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            rotationMatrix.columns.3 = SIMD4<Float>(0, 0, 0, 1)
            
            // Apply rotation to entity
            entity.transform.matrix = rotationMatrix
            
            // Add entity to anchor
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
            print("   ✅ Added framing box to AR scene")
            print("   ✅ Frame oriented to face camera")
            
            // Add center point indicator (small sphere)
            let centerIndicator = ModelEntity(
                mesh: MeshResource.generateSphere(radius: 0.05),
                materials: [SimpleMaterial(color: .green, isMetallic: false)]
            )
            centerIndicator.position = SIMD3<Float>(0, 0, 0.01)  // Slightly in front
            entity.addChild(centerIndicator)
            
            // Verify anchor is in scene
            if arView.scene.anchors.contains(where: { $0 === anchor }) {
                print("   ✅ Confirmed: Framing box is active in AR scene")
            }
        } else {
            print("   ❌ Error: Failed to create anchor or entity")
        }
    }
    
    func updateGuidanceBoxAlignment(subjectBounds: SubjectBounds, cameraTransform: simd_float4x4, in arView: ARView) {
        guard let guidanceBox = currentGuidanceBox,
              let anchor = guidanceAnchor,
              let entity = boxEntity else { return }
        
        // Calculate alignment quality based on:
        // 1. Distance from ideal position
        // 2. Subject centering in frame
        // 3. Size matching
        
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let cameraForward = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        
        // Check if subject is within the guidance frame
        let boxToSubject = subjectBounds.center - guidanceBox.targetPosition
        let lateralDistance = sqrt(boxToSubject.x * boxToSubject.x + boxToSubject.y * boxToSubject.y)
        
        // Calculate how centered the subject is (0 = perfect, 1 = at edge of frame)
        let halfFrameSize = guidanceBox.size.x / 2
        let centeringScore = 1.0 - min(lateralDistance / halfFrameSize, 1.0)
        
        // Calculate distance alignment
        let currentDistance = simd_length(subjectBounds.center - cameraPosition)
        let targetDistance = simd_length(guidanceBox.targetPosition - cameraPosition)
        let distanceError = abs(currentDistance - targetDistance)
        let distanceScore = 1.0 - min(distanceError / 2.0, 1.0)  // 2m tolerance
        
        // Combined alignment quality
        let alignmentQuality = Float((centeringScore + distanceScore) / 2.0)
        
        // Only update if quality changed significantly
        if abs(alignmentQuality - lastAlignmentQuality) > 0.1 {
            lastAlignmentQuality = alignmentQuality
            
            // Recreate entity with new color
            entity.removeFromParent()
            let newEntity = createGuidanceBoxEntity(guidanceBox: guidanceBox, alignmentQuality: alignmentQuality)
            
            // Apply same rotation as before
            let direction = normalize(cameraPosition - guidanceBox.targetPosition)
            let up = SIMD3<Float>(0, 1, 0)
            let right = normalize(cross(up, direction))
            let adjustedUp = cross(direction, right)
            
            var rotationMatrix = simd_float4x4()
            rotationMatrix.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
            rotationMatrix.columns.1 = SIMD4<Float>(adjustedUp.x, adjustedUp.y, adjustedUp.z, 0)
            rotationMatrix.columns.2 = SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            rotationMatrix.columns.3 = SIMD4<Float>(0, 0, 0, 1)
            
            newEntity.transform.matrix = rotationMatrix
            anchor.addChild(newEntity)
            boxEntity = newEntity
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
        
        // For stationary 2D frame, we don't update position after initial placement
        // The frame stays fixed in world space so users can align their camera with it
    }
    
    // Update box position based on current subject position
    func updateBoxPositionForSubject(subjectBounds: SubjectBounds, in arView: ARView) {
        // For stationary 2D frame, we don't update position after initial placement
        // The frame stays fixed in world space so users can align their camera with it
        return
    }
}


// MARK: - Guidance Overlay View
struct GuidanceOverlay: View {
    @ObservedObject var viewModel: ARViewModel
    
    var body: some View {
        // Use the new Apple-style alignment view
        AppleStyleAlignmentView(viewModel: viewModel)
            .allowsHitTesting(false)  // Don't block touch events
    }
}

struct DirectionalArrows: View {
    let directions: GuidanceDirections
    let screenSize: CGSize
    let targetBounds: CGRect
    
    var body: some View {
        ZStack {
            // Left arrow
            if directions.moveLeft > 0.1 {
                ArrowIndicator(direction: "left", magnitude: directions.moveLeft)
                    .position(x: 50, y: screenSize.height / 2)
            }
            
            // Right arrow
            if directions.moveRight > 0.1 {
                ArrowIndicator(direction: "right", magnitude: directions.moveRight)
                    .position(x: screenSize.width - 50, y: screenSize.height / 2)
            }
            
            // Up arrow
            if directions.moveUp > 0.1 {
                ArrowIndicator(direction: "up", magnitude: directions.moveUp)
                    .position(x: screenSize.width / 2, y: 50)
            }
            
            // Down arrow
            if directions.moveDown > 0.1 {
                ArrowIndicator(direction: "down", magnitude: directions.moveDown)
                    .position(x: screenSize.width / 2, y: screenSize.height - 100)
            }
            
            // Forward/Back indicators positioned below target box
            if directions.moveForward > 0.1 || directions.moveBack > 0.1 {
                DistanceIndicator(forward: directions.moveForward, back: directions.moveBack)
                    .position(x: screenSize.width / 2, 
                              y: min(targetBounds.maxY + 80, screenSize.height - 150))
            }
            
            // Rotation indicators (turn left/right)
            if directions.turnLeft > 0.1 || directions.turnRight > 0.1 {
                HStack(spacing: 40) {
                    if directions.turnLeft > 0.1 {
                        RotationIndicator(direction: "left", magnitude: directions.turnLeft)
                    }
                    if directions.turnRight > 0.1 {
                        RotationIndicator(direction: "right", magnitude: directions.turnRight)
                    }
                }
                .position(x: screenSize.width / 2, y: screenSize.height - 300)
            }
        }
    }
}

struct ArrowIndicator: View {
    let direction: String
    let magnitude: Float
    
    var arrowImage: String {
        switch direction {
        case "left": return "chevron.left"
        case "right": return "chevron.right"
        case "up": return "chevron.up"
        case "down": return "chevron.down"
        default: return "circle"
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 60, height: 60)
                
                Image(systemName: arrowImage)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
            }
            .shadow(radius: 4)
            
            Text(String(format: "%.1fm", magnitude))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .shadow(radius: 2)
        }
    }
}

struct DistanceIndicator: View {
    let forward: Float
    let back: Float
    
    var body: some View {
        HStack(spacing: 20) {
            if back > 0.1 {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "arrow.backward")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .shadow(radius: 4)
                    
                    Text(String(format: "%.1fm", back))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .shadow(radius: 2)
                }
            }
            
            if forward > 0.1 {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .shadow(radius: 4)
                    
                    Text(String(format: "%.1fm", forward))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .shadow(radius: 2)
                }
            }
        }
    }
}

struct RotationIndicator: View {
    let direction: String
    let magnitude: Float
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 50, height: 50)
                
                Image(systemName: direction == "left" ? "arrow.turn.up.left" : "arrow.turn.up.right")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(.white)
            }
            .shadow(radius: 4)
            
            Text(String(format: "%.0f°", magnitude))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .shadow(radius: 2)
        }
    }
}


struct RuleOfThirdsGuides: View {
    let frameSize: CGSize
    
    var body: some View {
        ZStack {
            // Vertical lines
            ForEach([1, 2], id: \.self) { index in
                Rectangle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 1, height: frameSize.height)
                    .position(x: frameSize.width * CGFloat(index) / 3.0,
                              y: frameSize.height / 2)
            }
            
            // Horizontal lines
            ForEach([1, 2], id: \.self) { index in
                Rectangle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: frameSize.width, height: 1)
                    .position(x: frameSize.width / 2,
                              y: frameSize.height * CGFloat(index) / 3.0)
            }
        }
    }
}

struct SubjectPositionIndicator: View {
    let subjectBounds: CGRect
    let isAligned: Bool
    
    var body: some View {
        // Semi-transparent overlay showing current subject position
        RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 2, dash: isAligned ? [] : [8, 4]))
            .foregroundColor(isAligned ? .green.opacity(0.5) : .white.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isAligned ? Color.green.opacity(0.1) : Color.clear)
            )
            .frame(width: subjectBounds.width, height: subjectBounds.height)
            .position(x: subjectBounds.midX, y: subjectBounds.midY)
            .animation(.easeInOut(duration: 0.3), value: isAligned)
        
        if !isAligned {
            Text("Current Position")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: subjectBounds.midX, y: subjectBounds.minY - 20)
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
        
        Section(header: Text("Performance Metrics")) {
          if viewModel.performanceMetrics.isEmpty {
            Text("No metrics recorded yet")
              .foregroundColor(.secondary)
          } else {
            ForEach(viewModel.performanceMetrics.reversed()) { metric in
              VStack(alignment: .leading, spacing: 4) {
                Text(metric.timestamp, style: .date)
                  .font(.caption.bold())
                HStack(spacing: 16) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text("Button→API: \(metric.formattedTimes.buttonToAPI)")
                      .font(.caption2)
                    Text("API Response: \(metric.formattedTimes.apiResponse)")
                      .font(.caption2)
                  }
                  VStack(alignment: .leading, spacing: 2) {
                    Text("Box Placement: \(metric.formattedTimes.boxPlacement)")
                      .font(.caption2)
                    Text("Total: \(metric.formattedTimes.total)")
                      .font(.caption2.bold())
                  }
                }
              }
              .padding(.vertical, 4)
            }
          }
          
          if !viewModel.performanceMetrics.isEmpty {
            Button(action: {
              viewModel.clearPerformanceMetrics()
            }) {
              HStack {
                Image(systemName: "trash")
                  .foregroundColor(.red)
                Text("Clear All Metrics")
                  .foregroundColor(.red)
              }
            }
          }
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
    var subjectRelativePitchDeg: String
    var subjectRelativeYawDeg: String
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
            subjectRelativePitchDeg: "",
            subjectRelativeYawDeg: "",
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
                            subjectRelativePitchDeg: "",
                            subjectRelativeYawDeg: "",
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

// MARK: - Performance Tracking
struct PerformanceMetric: Identifiable, Codable {
    let id = UUID()
    let timestamp: Date
    var buttonPressToAPICall: TimeInterval?
    var apiResponseTime: TimeInterval?
    var boxPlacementTime: TimeInterval?
    var totalTime: TimeInterval?
    
    var formattedTimes: (buttonToAPI: String, apiResponse: String, boxPlacement: String, total: String) {
        let formatter = { (time: TimeInterval?) -> String in
            guard let time = time else { return "N/A" }
            return String(format: "%.2fs", time)
        }
        return (
            buttonToAPI: formatter(buttonPressToAPICall),
            apiResponse: formatter(apiResponseTime),
            boxPlacement: formatter(boxPlacementTime),
            total: formatter(totalTime)
        )
    }
}

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
