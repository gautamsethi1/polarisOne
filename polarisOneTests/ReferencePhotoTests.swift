//
//  ReferencePhotoTests.swift
//  polarisOneTests
//
//  Tests for reference photo system, metadata storage, and comparison functionality
//

import Testing
import UIKit
import Foundation
@testable import polarisOne

/// Test suite for reference photo management and metadata system
struct ReferencePhotoTests {
    
    // MARK: - Mock Data Structures
    
    /// Mock reference image for testing
    struct MockReferenceImage {
        let id: UUID
        let image: UIImage
        let metadata: MockReferenceImageMetadata
        let captureDate: Date
        let thumbnailImage: UIImage?
        
        init(image: UIImage, metadata: MockReferenceImageMetadata) {
            self.id = UUID()
            self.image = image
            self.metadata = metadata
            self.captureDate = Date()
            self.thumbnailImage = createThumbnail(from: image)
        }
        
        private func createThumbnail(from image: UIImage) -> UIImage? {
            let thumbnailSize = CGSize(width: 150, height: 150)
            UIGraphicsBeginImageContextWithOptions(thumbnailSize, false, 0.0)
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
            let thumbnail = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return thumbnail
        }
    }
    
    /// Mock metadata structure matching the app's ReferenceImageMetadata
    struct MockReferenceImageMetadata {
        let distanceFromCamera: String
        let distanceBelowEyeline: String
        let cameraHeight: String
        let cameraHeightRelativeToEyes: String
        let visibleBodyParts: String
        let detectedSubjectCount: String
        let cameraRollDeg: String
        let cameraPitchDeg: String
        let cameraYawDeg: String
        let cameraFOVHDeg: String
        let ambientLux: String
        let colorTempK: String
        let captureDate: Date
        
        /// Create realistic metadata for testing
        static func createRealistic(
            distance: Float = 2.5,
            height: Float = 1.6,
            roll: Float = 0.0,
            pitch: Float = -5.0,
            yaw: Float = 0.0
        ) -> MockReferenceImageMetadata {
            return MockReferenceImageMetadata(
                distanceFromCamera: String(format: "%.1f", distance),
                distanceBelowEyeline: "0.1",
                cameraHeight: String(format: "%.2f", height),
                cameraHeightRelativeToEyes: "Cam 0.1m below eyes",
                visibleBodyParts: "head, shoulders, hands visible",
                detectedSubjectCount: "1",
                cameraRollDeg: String(format: "%.1f", roll),
                cameraPitchDeg: String(format: "%.1f", pitch),
                cameraYawDeg: String(format: "%.1f", yaw),
                cameraFOVHDeg: "60.0",
                ambientLux: "1200",
                colorTempK: "5600",
                captureDate: Date()
            )
        }
    }
    
    /// Mock reference image manager for testing
    class MockReferenceImageManager {
        private var storedImages: [UUID: MockReferenceImage] = [:]
        private let userDefaults = UserDefaults.standard
        
        func saveImage(_ image: UIImage, metadata: MockReferenceImageMetadata) -> MockReferenceImage? {
            let refImage = MockReferenceImage(image: image, metadata: metadata)
            storedImages[refImage.id] = refImage
            
            // Simulate persistent storage
            saveToUserDefaults()
            
            return refImage
        }
        
        func loadAllImages() -> [MockReferenceImage] {
            loadFromUserDefaults()
            return Array(storedImages.values).sorted { $0.captureDate > $1.captureDate }
        }
        
        func deleteImage(id: UUID) -> Bool {
            let removed = storedImages.removeValue(forKey: id)
            if removed != nil {
                saveToUserDefaults()
                return true
            }
            return false
        }
        
        func getImage(id: UUID) -> MockReferenceImage? {
            return storedImages[id]
        }
        
        private func saveToUserDefaults() {
            // Simulate saving metadata to UserDefaults (without actual images)
            let metadataArray = storedImages.values.map { image in
                return [
                    "id": image.id.uuidString,
                    "distance": image.metadata.distanceFromCamera,
                    "height": image.metadata.cameraHeight,
                    "captureDate": image.captureDate.timeIntervalSince1970
                ]
            }
            userDefaults.set(metadataArray, forKey: "test_reference_images")
        }
        
        private func loadFromUserDefaults() {
            // In real implementation, this would load from UserDefaults
            // For testing, we'll just maintain in-memory storage
        }
        
        func clearAllImages() {
            storedImages.removeAll()
            userDefaults.removeObject(forKey: "test_reference_images")
        }
    }
    
    // MARK: - Reference Image Storage Tests
    
    @Test("Reference image saving and retrieval")
    func testReferenceImageSavingAndRetrieval() throws {
        // Test basic save and load functionality
        
        // Arrange
        let manager = MockReferenceImageManager()
        let testImage = createTestImage(size: CGSize(width: 800, height: 600))
        let metadata = MockReferenceImageMetadata.createRealistic()
        
        // Act: Save image
        let savedImage = manager.saveImage(testImage, metadata: metadata)
        
        // Assert: Image should be saved successfully
        #expect(savedImage != nil, "Image should save successfully")
        #expect(savedImage?.image.size == testImage.size, "Saved image should maintain original size")
        
        // Act: Retrieve image
        let retrievedImage = manager.getImage(id: savedImage!.id)
        
        // Assert: Retrieved image should match saved image
        #expect(retrievedImage != nil, "Image should be retrievable")
        #expect(retrievedImage?.id == savedImage?.id, "Retrieved image should have same ID")
        #expect(retrievedImage?.metadata.distanceFromCamera == metadata.distanceFromCamera, "Metadata should be preserved")
    }
    
    @Test("Multiple reference images management")
    func testMultipleReferenceImagesManagement() throws {
        // Test managing multiple reference images
        
        // Arrange
        let manager = MockReferenceImageManager()
        manager.clearAllImages()
        
        var savedImages: [MockReferenceImage] = []
        
        // Act: Save multiple images with different metadata
        for i in 1...5 {
            let image = createTestImage(color: getColor(for: i))
            let metadata = MockReferenceImageMetadata.createRealistic(
                distance: Float(i) * 0.5 + 1.0, // 1.5, 2.0, 2.5, 3.0, 3.5
                height: Float(i) * 0.1 + 1.0    // 1.1, 1.2, 1.3, 1.4, 1.5
            )
            
            if let saved = manager.saveImage(image, metadata: metadata) {
                savedImages.append(saved)
            }
        }
        
        // Assert: All images should be saved
        #expect(savedImages.count == 5, "All 5 images should be saved")
        
        // Act: Retrieve all images
        let allImages = manager.loadAllImages()
        
        // Assert: All images should be retrievable
        #expect(allImages.count == 5, "All 5 images should be retrievable")
        
        // Assert: Images should be sorted by capture date (newest first)
        for i in 1..<allImages.count {
            #expect(allImages[i-1].captureDate >= allImages[i].captureDate, 
                   "Images should be sorted by capture date")
        }
    }
    
    @Test("Reference image deletion")
    func testReferenceImageDeletion() throws {
        // Test image deletion functionality
        
        // Arrange
        let manager = MockReferenceImageManager()
        manager.clearAllImages()
        
        let image1 = createTestImage(color: .red)
        let image2 = createTestImage(color: .blue)
        let metadata = MockReferenceImageMetadata.createRealistic()
        
        let saved1 = manager.saveImage(image1, metadata: metadata)!
        let saved2 = manager.saveImage(image2, metadata: metadata)!
        
        // Verify both images exist
        #expect(manager.loadAllImages().count == 2, "Should have 2 images before deletion")
        
        // Act: Delete first image
        let deleteResult = manager.deleteImage(id: saved1.id)
        
        // Assert: Deletion should succeed
        #expect(deleteResult == true, "Deletion should succeed")
        
        // Assert: Only second image should remain
        let remainingImages = manager.loadAllImages()
        #expect(remainingImages.count == 1, "Should have 1 image after deletion")
        #expect(remainingImages.first?.id == saved2.id, "Remaining image should be the second one")
        
        // Assert: Deleted image should not be retrievable
        let deletedImage = manager.getImage(id: saved1.id)
        #expect(deletedImage == nil, "Deleted image should not be retrievable")
    }
    
    // MARK: - Metadata Validation Tests
    
    @Test("Metadata field validation")
    func testMetadataFieldValidation() throws {
        // Test validation of metadata fields
        
        struct MetadataFieldTest {
            let field: String
            let value: String
            let isValid: Bool
            let description: String
        }
        
        let fieldTests: [MetadataFieldTest] = [
            // Distance validation
            MetadataFieldTest(field: "distance", value: "2.5", isValid: true, description: "Valid distance"),
            MetadataFieldTest(field: "distance", value: "0.5", isValid: true, description: "Minimum distance"),
            MetadataFieldTest(field: "distance", value: "10.0", isValid: true, description: "Maximum reasonable distance"),
            MetadataFieldTest(field: "distance", value: "-1.0", isValid: false, description: "Negative distance"),
            MetadataFieldTest(field: "distance", value: "N/A", isValid: false, description: "Invalid distance format"),
            
            // Height validation
            MetadataFieldTest(field: "height", value: "1.6", isValid: true, description: "Valid height"),
            MetadataFieldTest(field: "height", value: "0.0", isValid: true, description: "Ground level"),
            MetadataFieldTest(field: "height", value: "3.0", isValid: true, description: "High position"),
            MetadataFieldTest(field: "height", value: "-0.5", isValid: false, description: "Below ground"),
            
            // Angle validation  
            MetadataFieldTest(field: "angle", value: "0.0", isValid: true, description: "Zero angle"),
            MetadataFieldTest(field: "angle", value: "45.5", isValid: true, description: "Positive angle"),
            MetadataFieldTest(field: "angle", value: "-90.0", isValid: true, description: "Negative angle"),
            MetadataFieldTest(field: "angle", value: "180.0", isValid: true, description: "Maximum angle"),
            MetadataFieldTest(field: "angle", value: "400.0", isValid: false, description: "Excessive angle"),
            
            // Lighting validation
            MetadataFieldTest(field: "lux", value: "1000", isValid: true, description: "Valid lux"),
            MetadataFieldTest(field: "lux", value: "0", isValid: true, description: "Dark condition"),
            MetadataFieldTest(field: "lux", value: "100000", isValid: true, description: "Bright sunlight"),
            MetadataFieldTest(field: "lux", value: "-100", isValid: false, description: "Negative lux")
        ]
        
        for test in fieldTests {
            // Act: Validate field based on type
            var isValid = false
            
            switch test.field {
            case "distance", "height":
                if let value = Float(test.value) {
                    isValid = value >= 0 && value <= 20.0 // Reasonable bounds
                }
            case "angle":
                if let value = Float(test.value) {
                    isValid = value >= -180.0 && value <= 180.0
                }
            case "lux":
                if let value = Float(test.value) {
                    isValid = value >= 0 && value <= 200000 // 0 to bright sunlight
                }
            default:
                isValid = !test.value.isEmpty
            }
            
            // Assert: Validation should match expected result
            #expect(isValid == test.isValid, 
                   "Metadata validation failed for \(test.field): '\(test.value)' (\(test.description))")
        }
    }
    
    @Test("Metadata completeness validation")
    func testMetadataCompletenessValidation() throws {
        // Test validation of complete metadata sets
        
        // Arrange: Complete metadata
        let completeMetadata = MockReferenceImageMetadata.createRealistic()
        
        // Act: Validate completeness
        let requiredFields = [
            completeMetadata.distanceFromCamera,
            completeMetadata.cameraHeight,
            completeMetadata.cameraRollDeg,
            completeMetadata.cameraPitchDeg,
            completeMetadata.cameraYawDeg
        ]
        
        let hasAllRequiredFields = requiredFields.allSatisfy { !$0.isEmpty && $0 != "N/A" }
        
        // Assert: Complete metadata should be valid
        #expect(hasAllRequiredFields, "Complete metadata should have all required fields")
        
        // Test: Incomplete metadata
        let incompleteMetadata = MockReferenceImageMetadata(
            distanceFromCamera: "N/A", // Missing distance
            distanceBelowEyeline: "0.1",
            cameraHeight: "1.6",
            cameraHeightRelativeToEyes: "N/A", // Missing eye height
            visibleBodyParts: "unknown",
            detectedSubjectCount: "0", // No subjects
            cameraRollDeg: "0.0",
            cameraPitchDeg: "0.0",
            cameraYawDeg: "0.0",
            cameraFOVHDeg: "N/A", // Missing FOV
            ambientLux: "N/A", // Missing lighting
            colorTempK: "N/A", // Missing color temp
            captureDate: Date()
        )
        
        let incompleteFields = [
            incompleteMetadata.distanceFromCamera,
            incompleteMetadata.cameraHeightRelativeToEyes,
            incompleteMetadata.cameraFOVHDeg,
            incompleteMetadata.ambientLux
        ]
        
        let hasIncompleteFields = incompleteFields.contains { $0 == "N/A" || $0 == "unknown" }
        
        // Assert: Incomplete metadata should be detected
        #expect(hasIncompleteFields, "Incomplete metadata should be detected")
    }
    
    // MARK: - Image Comparison Tests
    
    @Test("Reference image comparison metadata")
    func testReferenceImageComparisonMetadata() throws {
        // Test metadata used for image comparison
        
        // Arrange: Two reference images with different capture conditions
        let referenceMetadata = MockReferenceImageMetadata.createRealistic(
            distance: 2.0,
            height: 1.5,
            roll: 0.0,
            pitch: -5.0,
            yaw: 0.0
        )
        
        let currentMetadata = MockReferenceImageMetadata.createRealistic(
            distance: 2.5, // 0.5m farther
            height: 1.7,   // 0.2m higher
            roll: 5.0,     // 5° roll difference
            pitch: -10.0,  // 5° pitch difference
            yaw: 0.0       // Same yaw
        )
        
        // Act: Calculate differences
        let distanceDiff = abs(Float(currentMetadata.distanceFromCamera)! - Float(referenceMetadata.distanceFromCamera)!)
        let heightDiff = abs(Float(currentMetadata.cameraHeight)! - Float(referenceMetadata.cameraHeight)!)
        let rollDiff = abs(Float(currentMetadata.cameraRollDeg)! - Float(referenceMetadata.cameraRollDeg)!)
        let pitchDiff = abs(Float(currentMetadata.cameraPitchDeg)! - Float(referenceMetadata.cameraPitchDeg)!)
        
        // Assert: Differences should be calculated correctly
        #expect(abs(distanceDiff - 0.5) < 0.01, "Distance difference should be 0.5m")
        #expect(abs(heightDiff - 0.2) < 0.01, "Height difference should be 0.2m")
        #expect(abs(rollDiff - 5.0) < 0.01, "Roll difference should be 5°")
        #expect(abs(pitchDiff - 5.0) < 0.01, "Pitch difference should be 5°")
        
        // Act: Determine if differences are significant
        let significantDistanceDiff = distanceDiff > 0.3 // 30cm threshold
        let significantHeightDiff = heightDiff > 0.15   // 15cm threshold
        let significantAngleDiff = max(rollDiff, pitchDiff) > 10.0 // 10° threshold
        
        // Assert: Should detect significant differences
        #expect(significantDistanceDiff, "Should detect significant distance difference")
        #expect(significantHeightDiff, "Should detect significant height difference")
        #expect(!significantAngleDiff, "Angle differences should not be significant")
    }
    
    @Test("Image composition comparison guidance")
    func testImageCompositionComparisonGuidance() throws {
        // Test generation of guidance based on metadata comparison
        
        struct ComparisonScenario {
            let referenceMeta: MockReferenceImageMetadata
            let currentMeta: MockReferenceImageMetadata
            let expectedGuidance: [String]
            let description: String
        }
        
        let scenarios: [ComparisonScenario] = [
            ComparisonScenario(
                referenceMeta: MockReferenceImageMetadata.createRealistic(distance: 2.0, height: 1.5),
                currentMeta: MockReferenceImageMetadata.createRealistic(distance: 3.0, height: 1.5),
                expectedGuidance: ["move_closer"],
                description: "Too far from subject"
            ),
            ComparisonScenario(
                referenceMeta: MockReferenceImageMetadata.createRealistic(distance: 3.0, height: 1.5),
                currentMeta: MockReferenceImageMetadata.createRealistic(distance: 1.5, height: 1.5),
                expectedGuidance: ["move_back"],
                description: "Too close to subject"
            ),
            ComparisonScenario(
                referenceMeta: MockReferenceImageMetadata.createRealistic(distance: 2.0, height: 1.8),
                currentMeta: MockReferenceImageMetadata.createRealistic(distance: 2.0, height: 1.3),
                expectedGuidance: ["raise_camera"],
                description: "Camera too low"
            ),
            ComparisonScenario(
                referenceMeta: MockReferenceImageMetadata.createRealistic(distance: 2.0, height: 1.3),
                currentMeta: MockReferenceImageMetadata.createRealistic(distance: 2.0, height: 1.8),
                expectedGuidance: ["lower_camera"],
                description: "Camera too high"
            )
        ]
        
        for scenario in scenarios {
            // Act: Generate guidance based on metadata differences
            var guidance: [String] = []
            
            let refDistance = Float(scenario.referenceMeta.distanceFromCamera)!
            let curDistance = Float(scenario.currentMeta.distanceFromCamera)!
            let distanceDiff = curDistance - refDistance
            
            let refHeight = Float(scenario.referenceMeta.cameraHeight)!
            let curHeight = Float(scenario.currentMeta.cameraHeight)!
            let heightDiff = curHeight - refHeight
            
            // Distance guidance
            if distanceDiff > 0.5 {
                guidance.append("move_closer")
            } else if distanceDiff < -0.5 {
                guidance.append("move_back")
            }
            
            // Height guidance
            if heightDiff < -0.3 {
                guidance.append("raise_camera")
            } else if heightDiff > 0.3 {
                guidance.append("lower_camera")
            }
            
            // Assert: Generated guidance should match expected
            #expect(guidance.count > 0, "Should generate guidance for \(scenario.description)")
            
            for expectedGuidanceItem in scenario.expectedGuidance {
                #expect(guidance.contains(expectedGuidanceItem), 
                       "Should generate '\(expectedGuidanceItem)' guidance for \(scenario.description)")
            }
        }
    }
    
    // MARK: - Thumbnail Generation Tests
    
    @Test("Thumbnail generation and sizing")
    func testThumbnailGenerationAndSizing() throws {
        // Test thumbnail creation for reference images
        
        // Arrange: Various image sizes
        let imageSizes = [
            CGSize(width: 400, height: 300),   // 4:3 landscape
            CGSize(width: 300, height: 400),   // 3:4 portrait
            CGSize(width: 1920, height: 1080), // HD landscape
            CGSize(width: 1080, height: 1920), // HD portrait
            CGSize(width: 100, height: 100)    // Small square
        ]
        
        for originalSize in imageSizes {
            // Act: Create image and thumbnail
            let originalImage = createTestImage(size: originalSize)
            let metadata = MockReferenceImageMetadata.createRealistic()
            let refImage = MockReferenceImage(image: originalImage, metadata: metadata)
            
            // Assert: Thumbnail should be created
            #expect(refImage.thumbnailImage != nil, "Thumbnail should be created for \(originalSize)")
            
            if let thumbnail = refImage.thumbnailImage {
                // Assert: Thumbnail should be reasonably sized
                let thumbnailSize = thumbnail.size
                #expect(thumbnailSize.width <= 150 && thumbnailSize.height <= 150, 
                       "Thumbnail should be within 150x150 bounds, got \(thumbnailSize)")
                
                // Assert: Thumbnail should maintain aspect ratio for non-square images
                let originalAspectRatio = originalSize.width / originalSize.height
                let thumbnailAspectRatio = thumbnailSize.width / thumbnailSize.height
                let aspectRatioDifference = abs(originalAspectRatio - thumbnailAspectRatio)
                
                #expect(aspectRatioDifference < 0.1, 
                       "Thumbnail should maintain aspect ratio for \(originalSize)")
            }
        }
    }
    
    // MARK: - Storage Performance Tests
    
    @Test("Reference image storage performance")
    func testReferenceImageStoragePerformance() throws {
        // Test performance with multiple reference images
        
        // Arrange
        let manager = MockReferenceImageManager()
        manager.clearAllImages()
        
        let imageCount = 20
        let imageSize = CGSize(width: 800, height: 600)
        
        // Act: Measure save performance
        let saveStartTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<imageCount {
            let image = createTestImage(size: imageSize, color: getColor(for: i))
            let metadata = MockReferenceImageMetadata.createRealistic(
                distance: Float(i) * 0.2 + 1.0,
                height: Float(i) * 0.05 + 1.0
            )
            let _ = manager.saveImage(image, metadata: metadata)
        }
        
        let saveTime = CFAbsoluteTimeGetCurrent() - saveStartTime
        
        // Assert: Save performance should be reasonable
        #expect(saveTime < 2.0, "Saving \(imageCount) images should complete within 2 seconds, took \(saveTime)s")
        
        // Act: Measure load performance
        let loadStartTime = CFAbsoluteTimeGetCurrent()
        let loadedImages = manager.loadAllImages()
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStartTime
        
        // Assert: Load performance should be reasonable
        #expect(loadTime < 0.5, "Loading \(imageCount) images should complete within 0.5 seconds, took \(loadTime)s")
        #expect(loadedImages.count == imageCount, "Should load all \(imageCount) images")
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage(size: CGSize = CGSize(width: 400, height: 300), color: UIColor = .lightGray) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Add some pattern for visual distinction
            UIColor.white.setFill()
            let rectSize: CGFloat = 20
            for x in stride(from: 0, to: size.width, by: rectSize * 2) {
                for y in stride(from: 0, to: size.height, by: rectSize * 2) {
                    context.fill(CGRect(x: x, y: y, width: rectSize, height: rectSize))
                }
            }
        }
    }
    
    private func getColor(for index: Int) -> UIColor {
        let colors: [UIColor] = [.red, .blue, .green, .orange, .purple, .brown, .cyan, .magenta, .yellow, .gray]
        return colors[index % colors.count]
    }
}

/// Test suite for persistent storage integration
struct ReferencePhotoStorageTests {
    
    @Test("UserDefaults integration for metadata")
    func testUserDefaultsIntegrationForMetadata() throws {
        // Test UserDefaults storage for reference image metadata
        
        // Arrange
        let testKey = "test_reference_metadata"
        let userDefaults = UserDefaults.standard
        
        // Clean up any existing test data
        userDefaults.removeObject(forKey: testKey)
        
        let metadata = ReferencePhotoTests.MockReferenceImageMetadata.createRealistic()
        
        // Act: Save metadata to UserDefaults
        let metadataDict: [String: Any] = [
            "distance": metadata.distanceFromCamera,
            "height": metadata.cameraHeight,
            "roll": metadata.cameraRollDeg,
            "pitch": metadata.cameraPitchDeg,
            "yaw": metadata.cameraYawDeg,
            "captureDate": metadata.captureDate.timeIntervalSince1970
        ]
        
        userDefaults.set(metadataDict, forKey: testKey)
        
        // Assert: Data should be saved
        let savedData = userDefaults.object(forKey: testKey) as? [String: Any]
        #expect(savedData != nil, "Metadata should be saved to UserDefaults")
        
        if let saved = savedData {
            #expect(saved["distance"] as? String == metadata.distanceFromCamera, "Distance should be preserved")
            #expect(saved["height"] as? String == metadata.cameraHeight, "Height should be preserved")
            #expect(saved["roll"] as? String == metadata.cameraRollDeg, "Roll should be preserved")
        }
        
        // Clean up
        userDefaults.removeObject(forKey: testKey)
    }
    
    @Test("File system storage for images")
    func testFileSystemStorageForImages() throws {
        // Test file system storage for reference images
        
        // Arrange
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let testImageURL = documentsURL.appendingPathComponent("test_reference.jpg")
        
        // Clean up any existing test file
        try? FileManager.default.removeItem(at: testImageURL)
        
        let testImage = createTestImage()
        
        // Act: Save image to file system
        guard let imageData = testImage.jpegData(compressionQuality: 0.8) else {
            Issue.record("Failed to create image data")
            return
        }
        
        do {
            try imageData.write(to: testImageURL)
        } catch {
            Issue.record("Failed to write image file: \(error)")
            return
        }
        
        // Assert: File should exist
        #expect(FileManager.default.fileExists(atPath: testImageURL.path), "Image file should exist")
        
        // Act: Load image from file system
        guard let loadedData = try? Data(contentsOf: testImageURL),
              let loadedImage = UIImage(data: loadedData) else {
            Issue.record("Failed to load image from file")
            return
        }
        
        // Assert: Loaded image should have similar properties
        #expect(loadedImage.size.width > 0 && loadedImage.size.height > 0, "Loaded image should have valid dimensions")
        
        // Clean up
        try? FileManager.default.removeItem(at: testImageURL)
    }
    
    private func createTestImage(size: CGSize = CGSize(width: 200, height: 200)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}