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

import SwiftUI
import UIKit // UIActivityViewController
import ARKit // plane / body / mesh detection
import RealityKit // ARView, debug overlays
import ModelIO // USDZ export helpers
import MetalKit // MTKMeshBufferAllocator
import Foundation // URL, Date, FileManager
import simd // simd_float4x4

// MARK: - Potential File: Extensions/URL+Identifiable.swift
// MARK: – Convenience so URL works with .sheet(item:)extension URL: Identifiable { public var id: String { absoluteString } }
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
    // Removed showPersonPrompt as we'll display distance directly
    // @Published var showPersonPrompt = false
    @Published var shareURL: URL?
    @Published var distanceToPerson: String = "Looking for subjects..." // Holds the distance string for UI
    @Published var detectedSubjectCount: Int = 0 // <-- ADD THIS LINE
}

// MARK: - Potential File: Views/ContentView.swift
// MARK: – Root SwiftUI view
struct ContentView: View {
    @StateObject private var vm = ARViewModel()
    var body: some View {
        // Change ZStack alignment to allow placing items in corners
        ZStack(alignment: .topLeading) { // <-- CHANGED ALIGNMENT
            ARViewContainer(viewModel: vm).ignoresSafeArea()

            // Overlay for distance and counter
            VStack(alignment: .leading) { // Use VStack for top-left info
                // Counter Display
                Text("Subjects: \(vm.detectedSubjectCount)")
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .font(.caption) // Make it a bit smaller

                Spacer() // Push distance text down within this corner area if needed

                // Display Distance Text Overlay (keep it at the bottom visually via Spacer in ZStack)
                // This Text is moved below, aligned to bottom
            }
            .padding() // Padding for the VStack contents

            // --- Bottom Aligned Content ---
            VStack { // Use another VStack for bottom content
                 Spacer() // Pushes content to the bottom

                 // Distance Text (moved here)
                 Text(vm.distanceToPerson)
                     .padding()
                     .background(.ultraThinMaterial)
                     .cornerRadius(10)
                     .padding(.bottom, 5) // Adjust spacing slightly

                 // Export Button (aligned bottom trailing)
                 HStack {
                     Spacer() // Push button to the right
                     Button(action: { vm.shareURL = ARMeshExporter.exportCurrentScene() }) {
                         Image(systemName: "square.and.arrow.up")
                             .font(.system(size: 24, weight: .bold))
                             .padding()
                             .background(.ultraThinMaterial, in: Circle())
                     }
                     .disabled(!ARMeshExporter.hasMesh)
                 }
            }
            .padding() // Padding for the VStack containing bottom elements
            // --- End Bottom Aligned Content ---

        }
        // Removed the simple alert
        .sheet(item: $vm.shareURL) { url in ActivityView(activityItems: [url]) }
    }
}
// MARK: - Potential File: Views/ARViewContainer.swift
// MARK: – UIViewRepresentable wrapping RealityKit
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARViewModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        guard ARWorldTrackingConfiguration.isSupported else {
            viewModel.distanceToPerson = "AR Not Supported"
            return view
        }

        // Session configuration
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal, .vertical]
        cfg.environmentTexturing = .automatic

        // ——— Scene reconstruction (requires a LiDAR‑equipped device)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            cfg.sceneReconstruction = .mesh
            view.debugOptions.insert([.showSceneUnderstanding, .showAnchorGeometry])
            print("✅ Scene Reconstruction enabled.")
        } else {
            print("⚠️ Scene Reconstruction not supported on this device – falling back to plane detection only")
        }

        // ——— Body detection (A12 Bionic+) - Keep using frame semantics for compatibility with plane/mesh
        // We need ARBodyAnchor updates, which this configuration provides.
        if ARBodyTrackingConfiguration.isSupported { // Check if body tracking itself is supported
             cfg.frameSemantics.insert(.bodyDetection)
             print("✅ Body Detection enabled.") // <-- Check console for this
        } else {
            print("⚠️ Body Detection not supported on this device.") // <-- Or this
            // Optionally inform the user via viewModel if body detection is crucial
            // viewModel.distanceToPerson = "Body Detection Not Supported"
        }


        view.debugOptions.formUnion([.showWorldOrigin, .showFeaturePoints])
        view.session.delegate = context.coordinator // Assign delegate
        view.session.run(cfg)

        // Coaching overlay
        let coach = ARCoachingOverlayView()
        coach.session = view.session
        coach.goal = .tracking // Goal can be adjusted if needed, e.g., .anyPlane for plane detection start
        coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coach.frame = view.bounds
        view.addSubview(coach)

        // Hand ARView to exporter
        ARMeshExporter.arView = view
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: viewModel)
    }

    // MARK: - Coordinator (ARSessionDelegate) - Updated with Debug Prints
    final class Coordinator: NSObject, ARSessionDelegate {
        private var vm: ARViewModel
        // Keep tracking one anchor for distance calculation consistency
        private var bodyAnchorTrackedForDistance: ARBodyAnchor?

        init(vm: ARViewModel) {
            self.vm = vm
            super.init()
            print("Coordinator Initialized")
        }

        // Called when anchors are added
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            print("✅ Session didAdd: \(anchors.count) anchors") // Changed emoji
            var foundBody = false
            for anchor in anchors {
                if anchor is ARMeshAnchor {
                    print("----> Found MESH ANCHOR on Add")
                    DispatchQueue.main.async { ARMeshExporter.hasMesh = true }
                }
                if anchor is ARBodyAnchor {
                     print("----> Found BODY ANCHOR on Add!")
                     foundBody = true
                }
            }

            // If we added a body anchor and weren't tracking one for distance, track the first one added
            if foundBody && bodyAnchorTrackedForDistance == nil {
                 bodyAnchorTrackedForDistance = anchors.compactMap { $0 as? ARBodyAnchor }.first
                 if bodyAnchorTrackedForDistance != nil {
                     print("----> Tracked first body anchor for distance: \(bodyAnchorTrackedForDistance!.identifier)")
                 }
            }

            // Note: The count is primarily updated in didUpdate based on *current* anchors
        }

        // Called when anchors are updated (including body anchors)
        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
             print("✅ Session didUpdate: \(anchors.count) anchors") // ADDED THIS AT THE VERY TOP

            // --- Counter Logic ---
            let currentBodyAnchors = anchors.compactMap { $0 as? ARBodyAnchor }
            let currentCount = currentBodyAnchors.count

            // --- Debug Print (Conditional) ---
            if !currentBodyAnchors.isEmpty {
                 print("----> Found \(currentBodyAnchors.count) BODY ANCHOR(s) in Update!")
            }

            DispatchQueue.main.async {
                if self.vm.detectedSubjectCount != currentCount {
                     self.vm.detectedSubjectCount = currentCount
                     print("----> Updated Subject Count: \(currentCount)")
                }
            }
            
            // --- Distance Logic ---
            // Try to find the anchor we were specifically tracking for distance
            var anchorForDistanceCalc: ARBodyAnchor? = nil
            if let trackedId = bodyAnchorTrackedForDistance?.identifier {
                anchorForDistanceCalc = currentBodyAnchors.first { $0.identifier == trackedId }
            }

            // If we lost the specific tracked anchor OR if we weren't tracking one but there ARE bodies,
            // pick the first available one for the distance calculation.
            if anchorForDistanceCalc == nil && !currentBodyAnchors.isEmpty {
                anchorForDistanceCalc = currentBodyAnchors.first
                bodyAnchorTrackedForDistance = anchorForDistanceCalc // Start tracking this one
                if let id = anchorForDistanceCalc?.identifier {
                     print("----> Switched distance tracking to anchor: \(id)")
                }
            } else if currentBodyAnchors.isEmpty {
                 // If no bodies are present, ensure we stop tracking
                 if bodyAnchorTrackedForDistance != nil {
                     print("----> Stopped tracking anchor for distance (none left).")
                     bodyAnchorTrackedForDistance = nil
                 }
            }


            // Calculate distance IF we have an anchor to calculate from
            if let targetAnchor = anchorForDistanceCalc, let cameraTransform = session.currentFrame?.camera.transform {
                let bodyTransform = targetAnchor.transform
                let cameraPosition = cameraTransform.translation
                let bodyPosition = bodyTransform.translation
                let distance = simd_distance(cameraPosition, bodyPosition)
                let distanceString = String(format: "%.1f m", distance)

                // Update distance on main thread
                DispatchQueue.main.async {
                    // Avoid redundant UI updates if the string is the same
                    if self.vm.distanceToPerson != distanceString {
                        self.vm.distanceToPerson = distanceString
                    }
                }
            } else if currentBodyAnchors.isEmpty {
                // If no bodies detected at all, reset distance text
                DispatchQueue.main.async {
                    let resetText = "Looking for subjects..."
                    if self.vm.distanceToPerson != resetText {
                         self.vm.distanceToPerson = resetText
                    }
                }
            }
             // If bodies are present but distance couldn't be calculated (e.g., no camera transform),
             // the distance text retains its last value, which might be acceptable.
        }
        
        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
             print("✅ Session didRemove: \(anchors.count) anchors") // Changed emoji
             // Check if the anchor we were tracking for distance was removed
            if let trackedId = bodyAnchorTrackedForDistance?.identifier,
               anchors.contains(where: { $0.identifier == trackedId && $0 is ARBodyAnchor }) {
                print("----> Tracked body anchor for distance REMOVED: \(trackedId)")
                bodyAnchorTrackedForDistance = nil
                // No need to reset count/distance here, didUpdate will handle it in the next frame
            }
        }

        // Optional: Handle session interruptions or errors if needed
        func session(_ session: ARSession, didFailWithError error: Error) {
            print("❌ AR Session Failed: \(error.localizedDescription)")
             // ... (rest of existing didFailWithError code) ...
        }

        func sessionWasInterrupted(_ session: ARSession) {
            print("⏸️ AR Session Interrupted") // ADDED/CHANGED PRINT
             DispatchQueue.main.async {
                 self.vm.distanceToPerson = "AR Session Interrupted"
             }
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            print("▶️ AR Session Interruption Ended") // ADDED/CHANGED PRINT
             DispatchQueue.main.async {
                 self.vm.distanceToPerson = "Looking for subjects..."
             }
        }
    }
}

// MARK: - Potential File: Utilities/ARMeshExporter.swift
// MARK: – Mesh Exporter (RealityKit → USDZ)
struct ARMeshExporter {
    static weak var arView: ARView?
    static var hasMesh = false // Keep track if mesh is available

    static func exportCurrentScene() -> URL? {
        guard let view = arView, hasMesh, // Ensure mesh is available before exporting
              let anchors = view.session.currentFrame?.anchors else {
            print("Export failed: ARView not set, no mesh, or no current anchors.")
            return nil
        }
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else {
             print("Export failed: No ARMeshAnchors found in the current frame.")
             return nil
        }

        print("Exporting \(meshes.count) mesh anchors...")
        let asset = MDLAsset()
                // Get the system's default Metal device for the allocator
        guard let device = MTLCreateSystemDefaultDevice() else { // <--- FIX
            print("Export failed: Could not get default Metal device.")
            return nil
        }
        let allocator = MTKMeshBufferAllocator(device: device) // Use the obtained device
        meshes.forEach { anchor in
            // Pass the allocator to the MDLMesh initializer
            asset.add(MDLMesh(arMeshAnchor: anchor, allocator: allocator))
        }

        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Export failed: Could not access documents directory.")
            return nil
        }

        // Use ISO8601 format for unique filenames
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime] // Ensure consistent format
        let fileName = "Scan_\(formatter.string(from: Date())).usdz"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)

        print("Attempting to export to: \(fileURL.path)")
        do {
            // Export the asset to the specified URL
            try asset.export(to: fileURL)
            print("✅ Export successful!")
            return fileURL
        } catch {
            print("❌ Export error: \(error.localizedDescription)")
            return nil
        }
    }
}


// MARK: - Potential File: Extensions/MDLMesh+ARMeshAnchor.swift
// MARK: – Build MDLMesh from ARMeshAnchor - Modified to accept allocator
extension MDLMesh {
    // Updated initializer to accept an allocator
    convenience init(arMeshAnchor a: ARMeshAnchor, allocator: MTKMeshBufferAllocator) {
        let g = a.geometry
        // vertices
        let vData = Data(bytesNoCopy: g.vertices.buffer.contents(), count: g.vertices.stride * g.vertices.count, deallocator: .none)
        // indices (three UInt32 per face)
        let fData = Data(bytesNoCopy: g.faces.buffer.contents(), count: g.faces.bytesPerIndex * g.faces.count * g.faces.indexCountPerPrimitive, deallocator: .none)

        // Use the passed-in allocator
        let vBuf = allocator.newBuffer(with: vData, type: .vertex)
        let iBuf = allocator.newBuffer(with: fData, type: .index)

        // Ensure index count calculation is correct
        let indexCount = g.faces.count * g.faces.indexCountPerPrimitive

        // Create the submesh
        let sub = MDLSubmesh(indexBuffer: iBuf,
                             indexCount: indexCount,
                             indexType: .uInt32, // Assuming 32-bit indices
                             geometryType: .triangles,
                             material: nil) // No material assigned here

        // Create the vertex descriptor based on ARGeometrySource format
        let descriptor = Self.vertexDescriptor(from: g.vertices)

        // Initialize the MDLMesh
        self.init(vertexBuffer: vBuf,
                  vertexCount: g.vertices.count,
                  descriptor: descriptor,
                  submeshes: [sub])

        // Apply the anchor's transform to the mesh
        self.transform = MDLTransform(matrix: a.transform)
    }

     // Helper function to create a vertex descriptor from ARGeometrySource
    static func vertexDescriptor(from source: ARGeometrySource) -> MDLVertexDescriptor {
        let descriptor = MDLVertexDescriptor()
        var offset = 0

        // Position attribute
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                     format: .float3, // Assuming vertices are float3
                                                     offset: offset,
                                                     bufferIndex: 0)
        offset += MemoryLayout<SIMD3<Float>>.stride

        // Add other attributes like normals or texture coordinates if available and needed
        // e.g., if normals were present:
        // descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: offset, bufferIndex: 0)
        // offset += MemoryLayout<SIMD3<Float>>.stride

        // Define the layout for the buffer
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: source.stride)

        return descriptor
    }
}

// MARK: - Potential File: Views/ActivityView.swift
// MARK: – UIKit share‑sheet wrapper - Unchanged
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiVC: UIActivityViewController, context: Context) {}
}

// MARK: - Potential File: Extensions/SIMD+Helpers.swift
// MARK: - SIMD Extension for Translation - Add this helper
extension simd_float4x4 {
    var translation: simd_float3 {
        // Construct a simd_float3 from the x, y, z components of the 4th column
        return simd_float3(columns.3.x, columns.3.y, columns.3.z) // <--- FIX
    }
}
