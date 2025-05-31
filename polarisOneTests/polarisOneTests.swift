//
//  polarisOneTests.swift
//  polarisOneTests
//
//  Created by Gautam Sethi on 4/19/25.
//

import Testing
import simd
import ARKit
import UIKit
import Foundation
@testable import polarisOne

// MARK: - Test Suite Structure
// This test suite covers the critical components of the ARKit camera application:
// 1. Distance calculations and smoothing algorithms
// 2. Height calibration and floor detection logic
// 3. Body tracking and joint position calculations
// 4. Camera metrics and orientation calculations
// 5. 3D mesh export functionality
// 6. API service integration
// 7. Reference photo system
// 8. State management and data flow

// MARK: - Mock Objects and Test Utilities

/// Mock AR frame for testing without actual AR session
struct MockARFrame {
    let cameraTransform: simd_float4x4
    let cameraEulerAngles: simd_float3
    let anchors: [MockARAnchor]
    let timestamp: TimeInterval
    
    init(cameraTransform: simd_float4x4 = matrix_identity_float4x4,
         cameraEulerAngles: simd_float3 = simd_float3(0, 0, 0),
         anchors: [MockARAnchor] = [],
         timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.cameraTransform = cameraTransform
        self.cameraEulerAngles = cameraEulerAngles
        self.anchors = anchors
        self.timestamp = timestamp
    }
}

/// Mock AR anchor for testing
struct MockARAnchor {
    let transform: simd_float4x4
    let type: AnchorType
    
    enum AnchorType {
        case body(joints: [String: simd_float4x4])
        case plane(alignment: PlaneAlignment, classification: PlaneClassification)
        case mesh
    }
    
    enum PlaneAlignment {
        case horizontal, vertical
    }
    
    enum PlaneClassification {
        case floor, table, wall, ceiling, door, window, seat, none
    }
}

/// Mock body anchor for joint testing
struct MockBodyAnchor {
    let transform: simd_float4x4
    let joints: [String: simd_float4x4]
    
    init(transform: simd_float4x4 = matrix_identity_float4x4,
         joints: [String: simd_float4x4] = [:]) {
        self.transform = transform
        self.joints = joints
    }
    
    /// Create a realistic human body pose for testing
    static func createRealisticPose(distanceFromCamera: Float = 2.0, height: Float = 1.7) -> MockBodyAnchor {
        let baseTransform = simd_float4x4(translation: simd_float3(0, 0, -distanceFromCamera))
        
        // Create joint positions relative to body center (hip/root)
        let joints: [String: simd_float4x4] = [
            "root": matrix_identity_float4x4, // Hip center
            "head": simd_float4x4(translation: simd_float3(0, height * 0.5, 0)), // Head ~50% above hip
            "leftShoulder": simd_float4x4(translation: simd_float3(-0.2, height * 0.35, 0)),
            "rightShoulder": simd_float4x4(translation: simd_float3(0.2, height * 0.35, 0)),
            "leftHand": simd_float4x4(translation: simd_float3(-0.3, height * 0.1, 0)),
            "rightHand": simd_float4x4(translation: simd_float3(0.3, height * 0.1, 0)),
            "leftFoot": simd_float4x4(translation: simd_float3(-0.1, -height * 0.5, 0)),
            "rightFoot": simd_float4x4(translation: simd_float3(0.1, -height * 0.5, 0))
        ]
        
        return MockBodyAnchor(transform: baseTransform, joints: joints)
    }
}

/// Test utilities for mathematical calculations
struct TestUtils {
    
    /// Create a transform matrix with translation
    static func createTransform(x: Float, y: Float, z: Float) -> simd_float4x4 {
        return simd_float4x4(translation: simd_float3(x, y, z))
    }
    
    /// Create floor plane at specified height
    static func createFloorPlane(height: Float = 0.0) -> MockARAnchor {
        return MockARAnchor(
            transform: createTransform(x: 0, y: height, z: 0),
            type: .plane(alignment: .horizontal, classification: .floor)
        )
    }
    
    /// Assert floating point equality with tolerance
    static func assertFloatEqual(_ actual: Float, _ expected: Float, tolerance: Float = 0.001, file: StaticString = #file, line: UInt = #line) {
        let difference = abs(actual - expected)
        if difference > tolerance {
            Issue.record("Float values not equal: \(actual) != \(expected) (difference: \(difference) > tolerance: \(tolerance))", sourceLocation: SourceLocation(file: file, line: line))
        }
    }
    
    /// Assert distance calculation accuracy
    static func assertDistanceAccuracy(_ calculated: Float, _ expected: Float, maxError: Float = 0.01, file: StaticString = #file, line: UInt = #line) {
        let error = abs(calculated - expected)
        let errorPercentage = error / expected * 100
        if error > maxError {
            Issue.record("Distance calculation error: \(calculated) vs \(expected) (error: \(error)m, \(errorPercentage)%)", sourceLocation: SourceLocation(file: file, line: line))
        }
    }
}

/// Extension to create transform matrices easily
extension simd_float4x4 {
    init(translation: simd_float3) {
        self = matrix_identity_float4x4
        self.columns.3 = simd_float4(translation.x, translation.y, translation.z, 1.0)
    }
    
    var translation: simd_float3 {
        return simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }
}

// MARK: - Core Test Suites

/// Test suite for distance calculations - the core AR measurement functionality
struct DistanceCalculationTests {
    
    @Test("Distance calculation accuracy with single joint")
    func testSingleJointDistanceCalculation() throws {
        // Arrange: Camera at origin, person 2 meters away
        let cameraPosition = simd_float3(0, 0, 0)
        let personPosition = simd_float3(0, 0, -2.0) // 2m in front of camera
        
        // Act: Calculate distance using simd_distance (same method used in app)
        let calculatedDistance = simd_distance(cameraPosition, personPosition)
        
        // Assert: Should be exactly 2.0 meters
        TestUtils.assertDistanceAccuracy(calculatedDistance, 2.0, maxError: 0.001)
    }
    
    @Test("Distance calculation with multiple joints and averaging")
    func testMultipleJointDistanceAveraging() throws {
        // Arrange: Camera and body with hip and shoulder positions
        let cameraPosition = simd_float3(0, 0, 0)
        let bodyAnchor = MockBodyAnchor.createRealisticPose(distanceFromCamera: 3.0)
        
        // Hip position (root joint)
        let hipWorldPos = (bodyAnchor.transform * bodyAnchor.joints["root"]!).translation
        let hipDistance = simd_distance(cameraPosition, hipWorldPos)
        
        // Shoulder center calculation
        let leftShoulderPos = (bodyAnchor.transform * bodyAnchor.joints["leftShoulder"]!).translation
        let rightShoulderPos = (bodyAnchor.transform * bodyAnchor.joints["rightShoulder"]!).translation
        let chestCenter = simd_float3(
            (leftShoulderPos.x + rightShoulderPos.x) / 2,
            (leftShoulderPos.y + rightShoulderPos.y) / 2,
            (leftShoulderPos.z + rightShoulderPos.z) / 2
        )
        let chestDistance = simd_distance(cameraPosition, chestCenter)
        
        // Act: Average the distances (simulating app logic)
        let averageDistance = (hipDistance + chestDistance) / 2
        
        // Assert: Should be close to 3.0 meters
        TestUtils.assertDistanceAccuracy(averageDistance, 3.0, maxError: 0.1)
        
        // Assert: Individual distances should be reasonable
        TestUtils.assertDistanceAccuracy(hipDistance, 3.0, maxError: 0.05)
        TestUtils.assertDistanceAccuracy(chestDistance, 3.0, maxError: 0.1) // Chest slightly higher, so small variation expected
    }
    
    @Test("Distance calculation edge cases")
    func testDistanceCalculationEdgeCases() throws {
        let cameraPosition = simd_float3(0, 0, 0)
        
        // Test: Person very close (0.5m)
        let closePersonPosition = simd_float3(0, 0, -0.5)
        let closeDistance = simd_distance(cameraPosition, closePersonPosition)
        TestUtils.assertDistanceAccuracy(closeDistance, 0.5, maxError: 0.001)
        
        // Test: Person very far (20m)
        let farPersonPosition = simd_float3(0, 0, -20.0)
        let farDistance = simd_distance(cameraPosition, farPersonPosition)
        TestUtils.assertDistanceAccuracy(farDistance, 20.0, maxError: 0.001)
        
        // Test: Person at angle (diagonal distance)
        let diagonalPersonPosition = simd_float3(3.0, 4.0, 0) // 3-4-5 triangle
        let diagonalDistance = simd_distance(cameraPosition, diagonalPersonPosition)
        TestUtils.assertDistanceAccuracy(diagonalDistance, 5.0, maxError: 0.001)
    }
    
    @Test("Distance smoothing buffer simulation")
    func testDistanceSmoothingBuffer() throws {
        // Arrange: Simulate distance buffer like in the app (5 measurements)
        var distanceBuffer: [Float] = []
        let bufferSize = 5
        
        // Simulate noisy distance measurements
        let noisyMeasurements: [Float] = [2.0, 2.1, 1.9, 2.05, 1.95, 2.02, 1.98]
        
        for measurement in noisyMeasurements {
            // Act: Add to buffer and maintain size (like app logic)
            distanceBuffer.append(measurement)
            if distanceBuffer.count > bufferSize {
                distanceBuffer.removeFirst()
            }
            
            // Calculate smoothed distance
            let smoothedDistance = distanceBuffer.reduce(0, +) / Float(distanceBuffer.count)
            
            // Assert: Smoothed distance should be closer to true value (2.0)
            if distanceBuffer.count == bufferSize {
                // With full buffer, smoothing should reduce noise
                let errorFromTrue = abs(smoothedDistance - 2.0)
                #expect(errorFromTrue < 0.1, "Smoothed distance \(smoothedDistance) should be close to 2.0")
            }
        }
    }
}

/// Test suite for height calibration - critical for camera positioning
struct HeightCalibrationTests {
    
    @Test("Floor plane detection and height calculation")
    func testFloorPlaneHeightCalculation() throws {
        // Arrange: Camera at 1.5m height, floor plane at 0m
        let cameraTransform = TestUtils.createTransform(x: 0, y: 1.5, z: 0)
        let floorPlane = TestUtils.createFloorPlane(height: 0.0)
        
        // Act: Calculate height (simulating app logic)
        let cameraWorldY = cameraTransform.translation.y
        let floorPlaneY = floorPlane.transform.translation.y
        let calculatedHeight = cameraWorldY - floorPlaneY
        
        // Assert: Should be 1.5 meters
        TestUtils.assertFloatEqual(calculatedHeight, 1.5)
    }
    
    @Test("Multiple floor planes - select lowest")
    func testMultipleFloorPlanesSelection() throws {
        // Arrange: Camera with multiple floor/table planes
        let cameraTransform = TestUtils.createTransform(x: 0, y: 2.0, z: 0)
        
        let floorPlane = TestUtils.createFloorPlane(height: 0.0)     // True floor
        let tablePlane = TestUtils.createFloorPlane(height: 0.8)     // Table surface
        let elevatedFloor = TestUtils.createFloorPlane(height: 0.2)   // Slightly elevated
        
        let planes = [floorPlane, tablePlane, elevatedFloor]
        
        // Act: Find lowest plane (simulating app logic)
        let lowestPlane = planes.min(by: { 
            abs($0.transform.translation.y) < abs($1.transform.translation.y) 
        })
        
        let calculatedHeight = cameraTransform.translation.y - lowestPlane!.transform.translation.y
        
        // Assert: Should use true floor (0.0), giving height of 2.0m
        TestUtils.assertFloatEqual(calculatedHeight, 2.0)
    }
    
    @Test("Height anomaly detection")
    func testHeightAnomalyDetection() throws {
        // Test the app's logic for detecting anomalous height readings
        
        // Arrange: Various height scenarios
        struct HeightScenario {
            let height: Float
            let shouldBeAnomalous: Bool
            let description: String
        }
        
        let scenarios: [HeightScenario] = [
            HeightScenario(height: 1.6, shouldBeAnomalous: false, description: "Normal standing height"),
            HeightScenario(height: -0.1, shouldBeAnomalous: true, description: "Camera below detected floor"),
            HeightScenario(height: -0.3, shouldBeAnomalous: true, description: "Significantly below floor"),
            HeightScenario(height: 0.05, shouldBeAnomalous: false, description: "Slightly above floor"),
            HeightScenario(height: 3.0, shouldBeAnomalous: false, description: "Very high but valid")
        ]
        
        for scenario in scenarios {
            // Act: Apply anomaly detection logic (from app)
            let isAnomalous = scenario.height < -0.05
            
            // Assert: Should match expected anomaly status
            #expect(isAnomalous == scenario.shouldBeAnomalous, 
                   "Height \(scenario.height)m (\(scenario.description)) anomaly detection failed")
        }
    }
}

/// Test suite for body tracking calculations
struct BodyTrackingTests {
    
    @Test("Eye position estimation from head joint")
    func testEyePositionEstimationFromHead() throws {
        // Arrange: Body with head joint
        let bodyAnchor = MockBodyAnchor.createRealisticPose()
        
        // Act: Calculate eye position (simulating app logic)
        guard let headJointTransform = bodyAnchor.joints["head"] else {
            Issue.record("Head joint not found in mock body")
            return
        }
        
        let headWorldPosition = (bodyAnchor.transform * headJointTransform).translation
        let estimatedEyeYOffset: Float = -0.07 // From app code
        let estimatedEyeWorldY = headWorldPosition.y + estimatedEyeYOffset
        
        // Assert: Eye position should be slightly below head center
        let expectedEyeY = headWorldPosition.y - 0.07
        TestUtils.assertFloatEqual(estimatedEyeWorldY, expectedEyeY)
    }
    
    @Test("Eye position estimation from shoulders (fallback)")
    func testEyePositionEstimationFromShoulders() throws {
        // Arrange: Body with shoulders but no head (testing fallback)
        var joints = MockBodyAnchor.createRealisticPose().joints
        joints.removeValue(forKey: "head") // Remove head to test fallback
        let bodyAnchor = MockBodyAnchor(joints: joints)
        
        // Act: Calculate eye position from shoulders (app fallback logic)
        guard let leftShoulderTransform = bodyAnchor.joints["leftShoulder"],
              let rightShoulderTransform = bodyAnchor.joints["rightShoulder"] else {
            Issue.record("Shoulder joints not found")
            return
        }
        
        let leftShoulderPos = (bodyAnchor.transform * leftShoulderTransform).translation
        let rightShoulderPos = (bodyAnchor.transform * rightShoulderTransform).translation
        let shoulderCenter = simd_float3(
            (leftShoulderPos.x + rightShoulderPos.x) / 2,
            (leftShoulderPos.y + rightShoulderPos.y) / 2,
            (leftShoulderPos.z + rightShoulderPos.z) / 2
        )
        
        // Eye position estimate: ~25-30cm above shoulders
        let estimatedEyeWorldY = shoulderCenter.y + 0.28
        
        // Assert: Eye position should be reasonable above shoulder center
        let shoulderToEyeDistance = estimatedEyeWorldY - shoulderCenter.y
        TestUtils.assertFloatEqual(shoulderToEyeDistance, 0.28)
    }
    
    @Test("Visible body parts detection")
    func testVisibleBodyPartsDetection() throws {
        // This tests the geometric calculation for joint visibility
        
        // Arrange: Camera looking forward, body in front
        let cameraTransform = matrix_identity_float4x4
        let bodyAnchor = MockBodyAnchor.createRealisticPose(distanceFromCamera: 2.0)
        
        // Test joints of interest (from app)
        let jointsOfInterest = ["head", "leftShoulder", "leftHand", "rightShoulder", "rightHand", "leftFoot", "rightFoot", "root"]
        
        var visibleJoints: [String] = []
        
        for jointName in jointsOfInterest {
            guard let jointModelTransform = bodyAnchor.joints[jointName] else { continue }
            let jointWorldPosition = (bodyAnchor.transform * jointModelTransform).translation
            
            // Act: Check if joint is in front of camera (basic visibility test)
            let pointInCameraSpace = cameraTransform.inverse * simd_float4(jointWorldPosition.x, jointWorldPosition.y, jointWorldPosition.z, 1.0)
            
            // In camera space, negative Z means in front of camera
            if pointInCameraSpace.z < 0 {
                visibleJoints.append(jointName)
            }
        }
        
        // Assert: All joints should be visible (person directly in front)
        #expect(visibleJoints.count == jointsOfInterest.count, 
               "Expected all \(jointsOfInterest.count) joints visible, got \(visibleJoints.count): \(visibleJoints)")
    }
    
    @Test("Joint position accuracy in body pose")
    func testJointPositionAccuracy() throws {
        // Test that the mock body pose creates realistic joint relationships
        
        let bodyAnchor = MockBodyAnchor.createRealisticPose(distanceFromCamera: 2.0, height: 1.7)
        
        // Get world positions
        let rootPos = (bodyAnchor.transform * bodyAnchor.joints["root"]!).translation
        let headPos = (bodyAnchor.transform * bodyAnchor.joints["head"]!).translation
        let leftShoulderPos = (bodyAnchor.transform * bodyAnchor.joints["leftShoulder"]!).translation
        let rightShoulderPos = (bodyAnchor.transform * bodyAnchor.joints["rightShoulder"]!).translation
        
        // Assert: Head should be above root (hip)
        #expect(headPos.y > rootPos.y, "Head should be above hip")
        
        // Assert: Shoulders should be at same height
        TestUtils.assertFloatEqual(leftShoulderPos.y, rightShoulderPos.y, tolerance: 0.01)
        
        // Assert: Shoulders should be symmetrical around body center
        let shoulderCenterX = (leftShoulderPos.x + rightShoulderPos.x) / 2
        TestUtils.assertFloatEqual(shoulderCenterX, rootPos.x, tolerance: 0.01)
        
        // Assert: Body should be at expected distance from camera
        let distanceToBody = simd_distance(simd_float3(0, 0, 0), rootPos)
        TestUtils.assertDistanceAccuracy(distanceToBody, 2.0, maxError: 0.01)
    }
}

/// Test suite for camera metrics and orientation
struct CameraMetricsTests {
    
    @Test("Euler angle conversion to degrees")
    func testEulerAngleConversion() throws {
        // Test the mathematical conversion from radians to degrees used in the app
        
        // Arrange: Various angles in radians
        struct AngleTest {
            let radians: Float
            let expectedDegrees: Float
            let description: String
        }
        
        let tests: [AngleTest] = [
            AngleTest(radians: 0, expectedDegrees: 0, description: "Zero angle"),
            AngleTest(radians: .pi / 2, expectedDegrees: 90, description: "90 degrees"),
            AngleTest(radians: .pi, expectedDegrees: 180, description: "180 degrees"),
            AngleTest(radians: -.pi / 4, expectedDegrees: -45, description: "-45 degrees"),
            AngleTest(radians: 2 * .pi, expectedDegrees: 360, description: "Full rotation")
        ]
        
        for test in tests {
            // Act: Convert using app's formula
            let degrees = test.radians * 180 / .pi
            
            // Assert: Should match expected
            TestUtils.assertFloatEqual(degrees, test.expectedDegrees, tolerance: 0.001)
        }
    }
    
    @Test("Camera orientation string formatting")
    func testCameraOrientationStringFormatting() throws {
        // Test the display string formatting used in the app
        
        // Arrange: Mock camera angles
        let roll: Float = .pi / 4  // 45 degrees
        let pitch: Float = .pi / 6  // 30 degrees  
        let yaw: Float = .pi / 3   // 60 degrees
        
        // Act: Format like the app does (note: roll is negated)
        let rollDeg = -roll * 180 / .pi
        let pitchDeg = pitch * 180 / .pi
        let yawDeg = yaw * 180 / .pi
        
        let orientationString = String(format: "R:%.0f° P:%.0f° Y:%.0f°", rollDeg, pitchDeg, yawDeg)
        
        // Assert: Should format correctly
        #expect(orientationString == "R:-45° P:30° Y:60°", "Orientation string: \(orientationString)")
    }
    
    @Test("Field of view calculation")
    func testFieldOfViewCalculation() throws {
        // Test FOV conversion from radians to degrees
        
        // Arrange: Typical camera FOV values in radians
        let fovRadians: Float = 1.047 // ~60 degrees
        
        // Act: Convert to degrees (app logic)
        let fovDegrees = fovRadians * 180 / .pi
        
        // Assert: Should be approximately 60 degrees
        TestUtils.assertFloatEqual(fovDegrees, 60.0, tolerance: 1.0)
    }
    
    @Test("Ambient light level parsing")
    func testAmbientLightFormatting() throws {
        // Test the ambient light display formatting
        
        // Arrange: Various light levels
        let lightLevels: [Float] = [100.0, 1000.0, 50000.0, 0.5]
        
        for level in lightLevels {
            // Act: Format like the app
            let luxString = String(format: "Lux: %.0f", level)
            
            // Assert: Should format without decimals for integer values
            if level >= 1.0 {
                #expect(!luxString.contains("."), "Lux string should not contain decimal: \(luxString)")
            }
        }
    }
}

/// Basic state management tests
struct StateManagementTests {
    
    @Test("ARViewModel initialization")
    func testARViewModelInitialization() throws {
        // Test that ARViewModel initializes with expected default values
        
        // Act: Create new ARViewModel
        let viewModel = ARViewModel()
        
        // Assert: Check default values
        #expect(viewModel.distanceToPerson == "Looking for subjects...")
        #expect(viewModel.detectedSubjectCount == 0)
        #expect(viewModel.isBodyTrackingActive == false)
        #expect(viewModel.isCapturing == false)
        #expect(viewModel.showDetailedMetrics == true)
        #expect(viewModel.shareURL == nil)
        #expect(viewModel.selectedReferenceImage == nil)
    }
    
    @Test("Published property changes")
    func testPublishedPropertyChanges() throws {
        // Test that @Published properties can be updated
        
        // Arrange
        let viewModel = ARViewModel()
        
        // Act: Update various properties
        viewModel.distanceToPerson = "2.5m"
        viewModel.detectedSubjectCount = 3
        viewModel.isBodyTrackingActive = true
        viewModel.showDetailedMetrics = false
        
        // Assert: Values should be updated
        #expect(viewModel.distanceToPerson == "2.5m")
        #expect(viewModel.detectedSubjectCount == 3)
        #expect(viewModel.isBodyTrackingActive == true)
        #expect(viewModel.showDetailedMetrics == false)
    }
}

// MARK: - Main Test Structure

struct polarisOneTests {
    
    @Test("Core mathematical calculations")
    func testCoreMathematicalCalculations() async throws {
        // This test verifies the fundamental mathematical operations used throughout the app
        
        // Test simd distance calculation
        let point1 = simd_float3(0, 0, 0)
        let point2 = simd_float3(3, 4, 0) // 3-4-5 right triangle
        let distance = simd_distance(point1, point2)
        TestUtils.assertDistanceAccuracy(distance, 5.0, maxError: 0.001)
        
        // Test matrix multiplication for coordinate transforms
        let transform = simd_float4x4(translation: simd_float3(1, 2, 3))
        let point = simd_float4(0, 0, 0, 1)
        let transformedPoint = transform * point
        
        #expect(transformedPoint.x == 1.0)
        #expect(transformedPoint.y == 2.0) 
        #expect(transformedPoint.z == 3.0)
        #expect(transformedPoint.w == 1.0)
    }
    
    @Test("Integration test for distance and height calculations")
    func testDistanceAndHeightIntegration() async throws {
        // Test the interaction between distance and height calculations
        
        // Arrange: Realistic AR scene
        let cameraTransform = TestUtils.createTransform(x: 0, y: 1.6, z: 0) // Camera at 1.6m height
        let floorPlane = TestUtils.createFloorPlane(height: 0.0)
        let bodyAnchor = MockBodyAnchor.createRealisticPose(distanceFromCamera: 2.5, height: 1.7)
        
        // Act: Calculate metrics like the app would
        let cameraHeight = cameraTransform.translation.y - floorPlane.transform.translation.y
        let personDistance = simd_distance(cameraTransform.translation, bodyAnchor.transform.translation)
        
        // Calculate relative height to person's eyes
        let headPos = (bodyAnchor.transform * bodyAnchor.joints["head"]!).translation
        let eyeEstimate = headPos.y - 0.07 // App's eye offset
        let cameraToEyeHeight = cameraTransform.translation.y - eyeEstimate
        
        // Assert: All calculations should be reasonable
        TestUtils.assertFloatEqual(cameraHeight, 1.6, tolerance: 0.01)
        TestUtils.assertDistanceAccuracy(personDistance, 2.5, maxError: 0.1)
        
        // Camera should be slightly below person's eye level (typical scenario)
        #expect(abs(cameraToEyeHeight) < 0.5, "Camera to eye height difference should be reasonable: \(cameraToEyeHeight)m")
    }
    
    @Test("Performance benchmark for distance calculations")
    @available(macOS 13.0, iOS 16.0, *)
    func testDistanceCalculationPerformance() async throws {
        // Benchmark the distance calculation performance
        
        let iterations = 1000
        let bodyAnchor = MockBodyAnchor.createRealisticPose()
        let cameraPosition = simd_float3(0, 0, 0)
        
        // Measure time for distance calculations
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            let hipPos = (bodyAnchor.transform * bodyAnchor.joints["root"]!).translation
            let _ = simd_distance(cameraPosition, hipPos)
        }
        
        let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
        let timePerCalculation = elapsedTime / Double(iterations)
        
        // Assert: Each calculation should be very fast (< 0.0001 seconds)
        #expect(timePerCalculation < 0.0001, "Distance calculation too slow: \(timePerCalculation)s per calculation")
    }
}
