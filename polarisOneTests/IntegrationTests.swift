//
//  IntegrationTests.swift
//  polarisOneTests
//
//  Integration tests for state management and component interactions
//

import Testing
import simd
import Combine
import Foundation
@testable import polarisOne

/// Test suite for integration scenarios and component interactions
struct IntegrationTests {
    
    // MARK: - Mock Classes for Integration Testing
    
    /// Mock ARViewModel for integration testing
    class MockARViewModel: ObservableObject {
        @Published var distanceToPerson: String = "Looking for subjects..."
        @Published var detectedSubjectCount: Int = 0
        @Published var cameraHeightRelativeToEyes: String = "Eyes: N/A"
        @Published var generalCameraHeight: String = "Cam Height: N/A"
        @Published var visibleBodyPartsInfo: String = "Visible Parts: N/A"
        @Published var bodyTrackingHint: String = ""
        @Published var isBodyTrackingActive: Bool = false
        @Published var isCapturing: Bool = false
        @Published var showResponses: Bool = false
        @Published var selectedReferenceImage: MockReferenceImage? = nil
        @Published var showDetailedMetrics: Bool = true
        
        // Camera metrics
        @Published var cameraRoll: Float?
        @Published var cameraPitch: Float?
        @Published var cameraYaw: Float?
        @Published var fieldOfViewHorizontalDeg: Float?
        @Published var ambientIntensityLux: Float?
        @Published var ambientColorTemperatureKelvin: Float?
        
        // Simulation state
        var isSimulatingARSession: Bool = false
        private var cancellables = Set<AnyCancellable>()
        
        func simulateBodyDetection(distance: Float, height: Float, visibleParts: [String]) {
            DispatchQueue.main.async {
                self.distanceToPerson = String(format: "%.1fm", distance)
                self.detectedSubjectCount = 1
                self.isBodyTrackingActive = true
                self.visibleBodyPartsInfo = visibleParts.joined(separator: ", ") + " visible"
                
                // Simulate height calculation
                self.generalCameraHeight = String(format: "Cam Height: %.2fm", height)
                self.cameraHeightRelativeToEyes = String(format: "Cam %.1fm below eyes", 0.1)
            }
        }
        
        func simulateCameraMetrics(roll: Float, pitch: Float, yaw: Float, fov: Float) {
            DispatchQueue.main.async {
                self.cameraRoll = roll
                self.cameraPitch = pitch
                self.cameraYaw = yaw
                self.fieldOfViewHorizontalDeg = fov
                self.ambientIntensityLux = 1200.0
                self.ambientColorTemperatureKelvin = 5600.0
            }
        }
        
        func simulatePhotoCapture() {
            DispatchQueue.main.async {
                self.isCapturing = true
            }
            
            // Simulate capture delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isCapturing = false
                self.bodyTrackingHint = "Photo captured with metrics"
            }
        }
        
        var cameraOrientationDegString: String {
            guard let roll = cameraRoll, let pitch = cameraPitch, let yaw = cameraYaw else { 
                return "Orientation: N/A" 
            }
            return String(format: "R:%.0f° P:%.0f° Y:%.0f°", -roll * 180 / .pi, pitch * 180 / .pi, yaw * 180 / .pi)
        }
    }
    
    /// Mock reference image structure for integration tests
    struct MockReferenceImage {
        let id: UUID = UUID()
        let image: UIImage
        let metadata: MockReferenceImageMetadata
        let captureDate: Date = Date()
        
        struct MockReferenceImageMetadata {
            let distanceFromCamera: String
            let cameraHeight: String
            let cameraRollDeg: String
            let cameraPitchDeg: String
            let cameraYawDeg: String
            let visibleBodyParts: String
            let detectedSubjectCount: String
        }
    }
    
    // MARK: - State Management Integration Tests
    
    @Test("ARViewModel state consistency during AR session simulation")
    func testARViewModelStateConsistency() async throws {
        // Test that ARViewModel maintains consistent state during simulated AR operations
        
        // Arrange
        let viewModel = MockARViewModel()
        var stateChanges: [String] = []
        var cancellables = Set<AnyCancellable>()
        
        // Monitor state changes
        viewModel.$isBodyTrackingActive
            .sink { isActive in
                stateChanges.append("bodyTracking:\(isActive)")
            }
            .store(in: &cancellables)
        
        viewModel.$detectedSubjectCount
            .sink { count in
                stateChanges.append("subjectCount:\(count)")
            }
            .store(in: &cancellables)
        
        viewModel.$isCapturing
            .sink { isCapturing in
                stateChanges.append("capturing:\(isCapturing)")
            }
            .store(in: &cancellables)
        
        // Act: Simulate AR session workflow
        
        // Step 1: Start with no detection
        #expect(viewModel.isBodyTrackingActive == false, "Should start with no body tracking")
        #expect(viewModel.detectedSubjectCount == 0, "Should start with no detected subjects")
        
        // Step 2: Simulate person detection
        viewModel.simulateBodyDetection(distance: 2.5, height: 1.6, visibleParts: ["head", "shoulders", "hands"])
        
        // Allow time for async updates
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Assert: Body tracking should be active
        #expect(viewModel.isBodyTrackingActive == true, "Body tracking should be active")
        #expect(viewModel.detectedSubjectCount == 1, "Should detect one subject")
        #expect(viewModel.distanceToPerson.contains("2.5"), "Distance should be updated")
        
        // Step 3: Simulate camera metrics update
        viewModel.simulateCameraMetrics(roll: 0.1, pitch: -0.087, yaw: 0.0, fov: 60.0)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Assert: Camera metrics should be updated
        #expect(viewModel.cameraRoll != nil, "Camera roll should be set")
        #expect(viewModel.fieldOfViewHorizontalDeg == 60.0, "FOV should be set")
        
        // Step 4: Simulate photo capture
        viewModel.simulatePhotoCapture()
        
        // Assert: Capture state should be active immediately
        #expect(viewModel.isCapturing == true, "Should be capturing")
        
        // Wait for capture to complete
        try await Task.sleep(nanoseconds: 600_000_000) // 0.6 seconds
        
        // Assert: Capture should be complete
        #expect(viewModel.isCapturing == false, "Capture should be complete")
        #expect(viewModel.bodyTrackingHint.contains("captured"), "Should show capture confirmation")
        
        // Cleanup
        cancellables.removeAll()
    }
    
    @Test("Published property synchronization")
    func testPublishedPropertySynchronization() async throws {
        // Test that @Published properties synchronize correctly across the view model
        
        // Arrange
        let viewModel = MockARViewModel()
        var receivedUpdates: [String: Any] = [:]
        var cancellables = Set<AnyCancellable>()
        
        // Monitor multiple published properties
        viewModel.$distanceToPerson
            .sink { distance in
                receivedUpdates["distance"] = distance
            }
            .store(in: &cancellables)
        
        viewModel.$generalCameraHeight
            .sink { height in
                receivedUpdates["height"] = height
            }
            .store(in: &cancellables)
        
        viewModel.$showDetailedMetrics
            .sink { show in
                receivedUpdates["showMetrics"] = show
            }
            .store(in: &cancellables)
        
        // Act: Update properties in sequence
        viewModel.distanceToPerson = "3.2m"
        viewModel.generalCameraHeight = "Cam Height: 1.75m"
        viewModel.showDetailedMetrics = false
        
        try await Task.sleep(nanoseconds: 50_000_000) // Allow time for updates
        
        // Assert: All updates should be received
        #expect(receivedUpdates["distance"] as? String == "3.2m", "Distance update should be received")
        #expect((receivedUpdates["height"] as? String)?.contains("1.75m") == true, "Height update should be received")
        #expect(receivedUpdates["showMetrics"] as? Bool == false, "Show metrics update should be received")
        
        // Cleanup
        cancellables.removeAll()
    }
    
    // MARK: - Data Flow Integration Tests
    
    @Test("Complete measurement workflow integration")
    func testCompleteMeasurementWorkflow() async throws {
        // Test the complete workflow from detection to measurement to display
        
        // Arrange
        let viewModel = MockARViewModel()
        
        // Act: Simulate complete measurement workflow
        
        // Step 1: Initial state
        #expect(viewModel.distanceToPerson == "Looking for subjects...", "Should start looking for subjects")
        
        // Step 2: Detect person at 2.0m distance, 1.5m height
        viewModel.simulateBodyDetection(distance: 2.0, height: 1.5, visibleParts: ["head", "shoulders"])
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Step 3: Update camera orientation
        viewModel.simulateCameraMetrics(roll: 0.05, pitch: -0.1, yaw: 0.0, fov: 58.5)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Assert: Complete measurement data should be available
        #expect(viewModel.distanceToPerson == "2.0m", "Distance should be measured")
        #expect(viewModel.generalCameraHeight.contains("1.5"), "Height should be measured")
        #expect(viewModel.cameraOrientationDegString.contains("R:"), "Orientation should be calculated")
        #expect(viewModel.visibleBodyPartsInfo.contains("head"), "Visible parts should be tracked")
        
        // Step 4: Test metric calculations
        let orientationString = viewModel.cameraOrientationDegString
        #expect(orientationString.contains("R:-3°"), "Roll should be converted to degrees (negated)")
        #expect(orientationString.contains("P:-6°"), "Pitch should be converted to degrees")
        #expect(orientationString.contains("Y:0°"), "Yaw should be converted to degrees")
    }
    
    @Test("Reference image workflow integration")
    func testReferenceImageWorkflowIntegration() async throws {
        // Test the workflow of capturing and using reference images
        
        // Arrange
        let viewModel = MockARViewModel()
        let testImage = createTestImage()
        
        // Act: Simulate reference image capture workflow
        
        // Step 1: Set up AR scene with measurements
        viewModel.simulateBodyDetection(distance: 2.5, height: 1.6, visibleParts: ["head", "shoulders", "hands"])
        viewModel.simulateCameraMetrics(roll: 0.0, pitch: -0.087, yaw: 0.0, fov: 60.0)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Step 2: Create reference image with current metrics
        let referenceMetadata = MockReferenceImage.MockReferenceImageMetadata(
            distanceFromCamera: "2.5",
            cameraHeight: "1.6",
            cameraRollDeg: "0.0",
            cameraPitchDeg: "-5.0",
            cameraYawDeg: "0.0",
            visibleBodyParts: "head, shoulders, hands visible",
            detectedSubjectCount: "1"
        )
        
        let referenceImage = MockReferenceImage(image: testImage, metadata: referenceMetadata)
        viewModel.selectedReferenceImage = referenceImage
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Assert: Reference image should be set
        #expect(viewModel.selectedReferenceImage != nil, "Reference image should be set")
        #expect(viewModel.selectedReferenceImage?.metadata.distanceFromCamera == "2.5", "Reference metadata should be preserved")
        
        // Step 3: Simulate scene change (person moves)
        viewModel.simulateBodyDetection(distance: 3.2, height: 1.6, visibleParts: ["head", "shoulders"])
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Assert: Current measurements should be different from reference
        #expect(viewModel.distanceToPerson == "3.2m", "Current distance should be updated")
        
        // Calculate difference from reference
        let currentDistance = Float(viewModel.distanceToPerson.replacingOccurrences(of: "m", with: ""))!
        let referenceDistance = Float(referenceImage.metadata.distanceFromCamera)!
        let distanceDifference = abs(currentDistance - referenceDistance)
        
        #expect(distanceDifference > 0.5, "Should detect significant difference from reference")
    }
    
    // MARK: - Error Handling Integration Tests
    
    @Test("Error recovery during state transitions")
    func testErrorRecoveryDuringStateTransitions() async throws {
        // Test how the system handles errors during state transitions
        
        // Arrange
        let viewModel = MockARViewModel()
        
        // Act: Simulate error conditions
        
        // Step 1: Normal operation
        viewModel.simulateBodyDetection(distance: 2.0, height: 1.5, visibleParts: ["head"])
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(viewModel.isBodyTrackingActive == true, "Should start with normal tracking")
        
        // Step 2: Simulate tracking loss (person moves out of frame)
        viewModel.detectedSubjectCount = 0
        viewModel.isBodyTrackingActive = false
        viewModel.distanceToPerson = "Looking for subjects..."
        viewModel.visibleBodyPartsInfo = "Visible Parts: N/A"
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Assert: Should handle tracking loss gracefully
        #expect(viewModel.detectedSubjectCount == 0, "Should show no detected subjects")
        #expect(viewModel.distanceToPerson == "Looking for subjects...", "Should show searching state")
        
        // Step 3: Simulate recovery (person returns)
        viewModel.simulateBodyDetection(distance: 1.8, height: 1.5, visibleParts: ["head", "shoulders"])
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Assert: Should recover tracking
        #expect(viewModel.isBodyTrackingActive == true, "Should recover tracking")
        #expect(viewModel.detectedSubjectCount == 1, "Should detect subject again")
        #expect(viewModel.distanceToPerson == "1.8m", "Should measure new distance")
    }
    
    @Test("Memory management during continuous operation")
    func testMemoryManagementDuringContinuousOperation() async throws {
        // Test memory management during continuous AR operation simulation
        
        // Arrange
        let viewModel = MockARViewModel()
        let initialMemoryFootprint = getApproximateMemoryUsage()
        
        // Act: Simulate continuous operation
        for i in 0..<100 {
            // Simulate frequent updates like a real AR session
            let distance = Float.random(in: 1.0...5.0)
            let height = Float.random(in: 1.0...2.5)
            let roll = Float.random(in: -0.2...0.2)
            let pitch = Float.random(in: -0.5...0.5)
            
            viewModel.simulateBodyDetection(
                distance: distance,
                height: height,
                visibleParts: ["head", "shoulders"]
            )
            
            viewModel.simulateCameraMetrics(
                roll: roll,
                pitch: pitch,
                yaw: 0.0,
                fov: 60.0
            )
            
            // Simulate processing delay
            if i % 10 == 0 {
                try await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
            }
        }
        
        // Allow final updates to settle
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let finalMemoryFootprint = getApproximateMemoryUsage()
        let memoryIncrease = finalMemoryFootprint - initialMemoryFootprint
        
        // Assert: Memory usage should not increase excessively
        #expect(memoryIncrease < 50_000_000, "Memory increase should be reasonable: \(memoryIncrease) bytes") // 50MB limit
        
        // Assert: Final state should be valid
        #expect(viewModel.detectedSubjectCount >= 0, "Subject count should be valid")
        #expect(!viewModel.distanceToPerson.isEmpty, "Distance should be set")
    }
    
    // MARK: - Performance Integration Tests
    
    @Test("Real-time update performance simulation")
    func testRealTimeUpdatePerformanceSimulation() async throws {
        // Test performance under simulated real-time AR update conditions
        
        // Arrange
        let viewModel = MockARViewModel()
        let updateCount = 60 // Simulate 60 updates (1 second at 60 FPS)
        
        // Act: Measure update performance
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<updateCount {
            // Simulate AR frame update (typical 60 FPS scenario)
            let distance = 2.0 + sin(Double(i) * 0.1) * 0.5 // Simulate natural movement
            let height = 1.6 + cos(Double(i) * 0.1) * 0.1
            
            viewModel.simulateBodyDetection(
                distance: Float(distance),
                height: Float(height),
                visibleParts: ["head", "shoulders"]
            )
            
            viewModel.simulateCameraMetrics(
                roll: Float(sin(Double(i) * 0.05) * 0.1),
                pitch: Float(cos(Double(i) * 0.05) * 0.1),
                yaw: 0.0,
                fov: 60.0
            )
            
            // Simulate minimal frame time
            try await Task.sleep(nanoseconds: 1_000_000) // 0.001 seconds
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let averageUpdateTime = totalTime / Double(updateCount)
        
        // Assert: Updates should be fast enough for real-time operation
        #expect(averageUpdateTime < 0.016, "Average update time should be under 16ms (60 FPS), got \(averageUpdateTime * 1000)ms")
        #expect(totalTime < 2.0, "Total update time should be reasonable, got \(totalTime)s")
        
        // Assert: Final state should be valid after continuous updates
        #expect(viewModel.isBodyTrackingActive == true, "Should maintain tracking through updates")
        #expect(Float(viewModel.distanceToPerson.replacingOccurrences(of: "m", with: "")) != nil, "Distance should be numeric")
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage(size: CGSize = CGSize(width: 400, height: 300)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.lightGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Add test pattern
            UIColor.blue.setFill()
            context.fill(CGRect(x: size.width * 0.2, y: size.height * 0.2,
                               width: size.width * 0.6, height: size.height * 0.6))
        }
    }
    
    private func getApproximateMemoryUsage() -> Int {
        // Simple approximation of memory usage for testing
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Int(info.resident_size)
        }
        return 0
    }
}

/// Test suite for cross-component communication
struct ComponentCommunicationTests {
    
    @Test("View model to API service communication")
    func testViewModelToAPIServiceCommunication() async throws {
        // Test communication between view model and API service
        
        // Arrange
        let viewModel = IntegrationTests.MockARViewModel()
        
        // Set up realistic AR state
        viewModel.simulateBodyDetection(distance: 2.3, height: 1.65, visibleParts: ["head", "shoulders", "hands"])
        viewModel.simulateCameraMetrics(roll: 0.05, pitch: -0.087, yaw: 0.0, fov: 60.0)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Act: Prepare data for API service (simulating app logic)
        let apiMetrics: [String: String] = [
            "distance_to_person_meters": viewModel.distanceToPerson.replacingOccurrences(of: "m", with: ""),
            "camera_height_meters": "1.65",
            "camera_roll_deg": String(format: "%.1f", -(viewModel.cameraRoll ?? 0) * 180 / .pi),
            "camera_pitch_deg": String(format: "%.1f", (viewModel.cameraPitch ?? 0) * 180 / .pi),
            "camera_yaw_deg": String(format: "%.1f", (viewModel.cameraYaw ?? 0) * 180 / .pi),
            "visible_body_parts": viewModel.visibleBodyPartsInfo,
            "detected_subject_count": "\(viewModel.detectedSubjectCount)",
            "camera_fov_h_deg": String(format: "%.1f", viewModel.fieldOfViewHorizontalDeg ?? 0),
            "ambient_lux": String(format: "%.0f", viewModel.ambientIntensityLux ?? 0),
            "color_temp_k": String(format: "%.0f", viewModel.ambientColorTemperatureKelvin ?? 0)
        ]
        
        // Assert: API metrics should be properly formatted
        #expect(apiMetrics["distance_to_person_meters"] == "2.3", "Distance should be formatted for API")
        #expect(apiMetrics["camera_roll_deg"] != nil, "Roll should be converted to degrees")
        #expect(apiMetrics["visible_body_parts"]?.contains("head") == true, "Body parts should be included")
        #expect(apiMetrics["detected_subject_count"] == "1", "Subject count should be included")
        
        // Verify all required metrics are present and non-empty
        let requiredKeys = ["distance_to_person_meters", "camera_height_meters", "camera_roll_deg", 
                           "camera_pitch_deg", "camera_yaw_deg", "visible_body_parts"]
        
        for key in requiredKeys {
            #expect(apiMetrics[key] != nil && !apiMetrics[key]!.isEmpty, 
                   "Required metric '\(key)' should be present and non-empty")
        }
    }
    
    @Test("Reference image to comparison workflow")
    func testReferenceImageToComparisonWorkflow() async throws {
        // Test the workflow from reference image to comparison analysis
        
        // Arrange
        let viewModel = IntegrationTests.MockARViewModel()
        
        // Create reference image with specific metrics
        let referenceImage = IntegrationTests.MockReferenceImage(
            image: createTestImage(),
            metadata: IntegrationTests.MockReferenceImage.MockReferenceImageMetadata(
                distanceFromCamera: "2.0",
                cameraHeight: "1.6",
                cameraRollDeg: "0.0",
                cameraPitchDeg: "-5.0",
                cameraYawDeg: "0.0",
                visibleBodyParts: "head, shoulders visible",
                detectedSubjectCount: "1"
            )
        )
        
        viewModel.selectedReferenceImage = referenceImage
        
        // Set current scene with different metrics
        viewModel.simulateBodyDetection(distance: 2.8, height: 1.8, visibleParts: ["head", "shoulders"])
        viewModel.simulateCameraMetrics(roll: 0.087, pitch: -0.174, yaw: 0.0, fov: 60.0)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Act: Compare current metrics with reference
        let referenceDistance = Float(referenceImage.metadata.distanceFromCamera)!
        let currentDistance = Float(viewModel.distanceToPerson.replacingOccurrences(of: "m", with: ""))!
        let distanceDiff = currentDistance - referenceDistance
        
        let referenceHeight = Float(referenceImage.metadata.cameraHeight)!
        let currentHeight: Float = 1.8 // From simulation
        let heightDiff = currentHeight - referenceHeight
        
        let referencePitch = Float(referenceImage.metadata.cameraPitchDeg)!
        let currentPitch = (viewModel.cameraPitch ?? 0) * 180 / .pi
        let pitchDiff = currentPitch - referencePitch
        
        // Assert: Differences should be calculated correctly
        #expect(abs(distanceDiff - 0.8) < 0.1, "Distance difference should be approximately 0.8m")
        #expect(abs(heightDiff - 0.2) < 0.1, "Height difference should be approximately 0.2m")
        #expect(abs(pitchDiff - (-5.0)) < 2.0, "Pitch difference should be reasonable")
        
        // Act: Generate guidance based on differences
        var guidance: [String] = []
        
        if distanceDiff > 0.5 {
            guidance.append("Move closer to match reference distance")
        }
        if heightDiff > 0.15 {
            guidance.append("Lower camera to match reference height")
        }
        if abs(pitchDiff) > 3.0 {
            guidance.append("Adjust camera angle to match reference")
        }
        
        // Assert: Appropriate guidance should be generated
        #expect(guidance.contains { $0.contains("closer") }, "Should suggest moving closer")
        #expect(guidance.contains { $0.contains("Lower") }, "Should suggest lowering camera")
    }
    
    private func createTestImage(size: CGSize = CGSize(width: 300, height: 200)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}"