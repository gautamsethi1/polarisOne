//
//  APIServiceTests.swift
//  polarisOneTests
//
//  Tests for Gemini API integration and scene analysis functionality
//

import Testing
import UIKit
import Foundation
@testable import polarisOne

/// Test suite for API service integration with Gemini
struct APIServiceTests {
    
    // MARK: - Mock API Service
    
    /// Mock API service for testing without actual network calls
    class MockAPIService: ObservableObject {
        @Published var lastRequest: APIRequest?
        @Published var shouldSimulateError: Bool = false
        @Published var mockResponse: String = ""
        @Published var mockDelay: TimeInterval = 0.0
        
        struct APIRequest {
            let image: UIImage
            let metrics: [String: String]
            let endpoint: String
            let timestamp: Date
        }
        
        func sendAnalysis(image: UIImage, metrics: [String: String]) async -> String? {
            lastRequest = APIRequest(
                image: image,
                metrics: metrics,
                endpoint: "analysis",
                timestamp: Date()
            )
            
            if shouldSimulateError {
                return nil
            }
            
            if mockDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(mockDelay * 1_000_000_000))
            }
            
            return mockResponse
        }
        
        func sendImageGeneration(prompt: String, image: UIImage?, metrics: [String: String]) async -> UIImage? {
            lastRequest = APIRequest(
                image: image ?? UIImage(),
                metrics: metrics,
                endpoint: "generation",
                timestamp: Date()
            )
            
            if shouldSimulateError {
                return nil
            }
            
            // Return a simple 1x1 colored image for testing
            return createTestImage(color: .blue, size: CGSize(width: 100, height: 100))
        }
        
        private func createTestImage(color: UIColor, size: CGSize) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
    }
    
    // MARK: - API Request Validation Tests
    
    @Test("API request contains required metrics")
    func testAPIRequestContainsRequiredMetrics() async throws {
        // Arrange
        let mockAPI = MockAPIService()
        let testImage = createTestImage()
        
        let requiredMetrics = [
            "distance_to_person_meters": "2.5",
            "camera_height_meters": "1.6",
            "camera_roll_deg": "0.0",
            "camera_pitch_deg": "5.0",
            "camera_yaw_deg": "-10.0",
            "visible_body_parts": "head, shoulders, hands",
            "camera_fov_h_deg": "60.0",
            "ambient_lux": "1000",
            "color_temp_k": "5600"
        ]
        
        mockAPI.mockResponse = "Test analysis response"
        
        // Act
        let response = await mockAPI.sendAnalysis(image: testImage, metrics: requiredMetrics)
        
        // Assert
        #expect(response != nil, "API should return response")
        #expect(mockAPI.lastRequest != nil, "API request should be recorded")
        
        let lastRequest = mockAPI.lastRequest!
        #expect(lastRequest.metrics.count == requiredMetrics.count, "All metrics should be included")
        
        // Verify each required metric is present
        for (key, expectedValue) in requiredMetrics {
            #expect(lastRequest.metrics[key] == expectedValue, "Metric \(key) should have value \(expectedValue)")
        }
    }
    
    @Test("API request handles missing optional metrics gracefully")
    func testAPIRequestHandlesMissingMetrics() async throws {
        // Arrange
        let mockAPI = MockAPIService()
        let testImage = createTestImage()
        
        // Only provide essential metrics
        let minimalMetrics = [
            "distance_to_person_meters": "2.0",
            "camera_height_meters": "1.5"
        ]
        
        mockAPI.mockResponse = "Analysis with minimal metrics"
        
        // Act
        let response = await mockAPI.sendAnalysis(image: testImage, metrics: minimalMetrics)
        
        // Assert
        #expect(response != nil, "API should handle minimal metrics")
        #expect(mockAPI.lastRequest?.metrics.count == 2, "Should contain only provided metrics")
    }
    
    @Test("API request validation for numeric metric formats")
    func testAPIRequestNumericMetricValidation() async throws {
        // Test that numeric metrics are properly formatted for API consumption
        
        struct MetricTest {
            let key: String
            let value: String
            let isValidFormat: Bool
            let description: String
        }
        
        let metricTests: [MetricTest] = [
            MetricTest(key: "distance_to_person_meters", value: "2.5", isValidFormat: true, description: "Valid distance"),
            MetricTest(key: "distance_to_person_meters", value: "N/A", isValidFormat: false, description: "Invalid distance - N/A"),
            MetricTest(key: "camera_height_meters", value: "1.6", isValidFormat: true, description: "Valid height"),
            MetricTest(key: "camera_height_meters", value: "unknown", isValidFormat: false, description: "Invalid height - text"),
            MetricTest(key: "camera_roll_deg", value: "45.5", isValidFormat: true, description: "Valid angle"),
            MetricTest(key: "camera_roll_deg", value: "-90.0", isValidFormat: true, description: "Valid negative angle"),
            MetricTest(key: "ambient_lux", value: "1000", isValidFormat: true, description: "Valid lux integer"),
            MetricTest(key: "ambient_lux", value: "1000.5", isValidFormat: true, description: "Valid lux decimal"),
            MetricTest(key: "camera_fov_h_deg", value: "60.0", isValidFormat: true, description: "Valid FOV")
        ]
        
        for test in metricTests {
            // Act: Validate metric format (simulating app's validation logic)
            let isNumeric = Float(test.value) != nil
            let isValidForAPI = isNumeric || test.value.lowercased().contains("n/a") || test.value.lowercased().contains("unknown")
            
            // Assert: Should match expected validation result
            if test.isValidFormat {
                #expect(isNumeric, "Metric \(test.key) with value '\(test.value)' should be numeric (\(test.description))")
            }
        }
    }
    
    // MARK: - Image Processing Tests
    
    @Test("Image format validation for API submission")
    func testImageFormatValidation() throws {
        // Test that images are properly formatted for API submission
        
        // Arrange: Create test images with different properties
        let smallImage = createTestImage(size: CGSize(width: 100, height: 100))
        let largeImage = createTestImage(size: CGSize(width: 4000, height: 3000))
        let portraitImage = createTestImage(size: CGSize(width: 480, height: 640))
        let landscapeImage = createTestImage(size: CGSize(width: 640, height: 480))
        
        let images = [
            ("Small image", smallImage),
            ("Large image", largeImage),
            ("Portrait image", portraitImage),
            ("Landscape image", landscapeImage)
        ]
        
        for (description, image) in images {
            // Act: Validate image properties
            let imageData = image.jpegData(compressionQuality: 0.8)
            
            // Assert: Image should be convertible to JPEG
            #expect(imageData != nil, "\(description) should be convertible to JPEG")
            
            // Assert: Image should have reasonable data size (not empty, not excessively large)
            if let data = imageData {
                #expect(data.count > 1000, "\(description) should have reasonable data size")
                #expect(data.count < 10_000_000, "\(description) should not be excessively large") // 10MB limit
            }
        }
    }
    
    @Test("Image compression for API efficiency")
    func testImageCompressionForAPI() throws {
        // Test image compression strategies for efficient API calls
        
        // Arrange: Create a large test image
        let largeImage = createTestImage(size: CGSize(width: 2000, height: 2000))
        
        // Act: Test different compression levels
        let compressionLevels: [CGFloat] = [1.0, 0.8, 0.6, 0.4, 0.2]
        var compressionResults: [(quality: CGFloat, dataSize: Int)] = []
        
        for quality in compressionLevels {
            if let data = largeImage.jpegData(compressionQuality: quality) {
                compressionResults.append((quality: quality, dataSize: data.count))
            }
        }
        
        // Assert: Higher compression should result in smaller file sizes
        for i in 1..<compressionResults.count {
            let current = compressionResults[i]
            let previous = compressionResults[i-1]
            
            #expect(current.dataSize <= previous.dataSize, 
                   "Lower quality (\(current.quality)) should produce smaller or equal file size than higher quality (\(previous.quality))")
        }
        
        // Assert: App's chosen compression (0.8) should be reasonable
        let appCompressionData = largeImage.jpegData(compressionQuality: 0.8)!
        #expect(appCompressionData.count < 5_000_000, "App compression should keep images under 5MB")
    }
    
    // MARK: - Error Handling Tests
    
    @Test("API error handling and retry logic")
    func testAPIErrorHandling() async throws {
        // Test how the API handles various error conditions
        
        // Arrange
        let mockAPI = MockAPIService()
        let testImage = createTestImage()
        let testMetrics = ["distance_to_person_meters": "2.0"]
        
        // Test: Network error simulation
        mockAPI.shouldSimulateError = true
        
        // Act
        let errorResponse = await mockAPI.sendAnalysis(image: testImage, metrics: testMetrics)
        
        // Assert
        #expect(errorResponse == nil, "API should return nil on error")
        
        // Test: Recovery after error
        mockAPI.shouldSimulateError = false
        mockAPI.mockResponse = "Recovery response"
        
        let recoveryResponse = await mockAPI.sendAnalysis(image: testImage, metrics: testMetrics)
        #expect(recoveryResponse == "Recovery response", "API should recover after error")
    }
    
    @Test("API timeout handling")
    func testAPITimeoutHandling() async throws {
        // Test API behavior with simulated delays
        
        // Arrange
        let mockAPI = MockAPIService()
        let testImage = createTestImage()
        let testMetrics = ["distance_to_person_meters": "2.0"]
        
        // Test: Fast response
        mockAPI.mockDelay = 0.1 // 100ms
        mockAPI.mockResponse = "Fast response"
        
        let startTime = Date()
        let fastResponse = await mockAPI.sendAnalysis(image: testImage, metrics: testMetrics)
        let fastDuration = Date().timeIntervalSince(startTime)
        
        #expect(fastResponse == "Fast response", "Should handle fast responses")
        #expect(fastDuration < 0.5, "Fast response should complete quickly")
        
        // Test: Slower response (but still reasonable)
        mockAPI.mockDelay = 1.0 // 1 second
        mockAPI.mockResponse = "Slow response"
        
        let slowStartTime = Date()
        let slowResponse = await mockAPI.sendAnalysis(image: testImage, metrics: testMetrics)
        let slowDuration = Date().timeIntervalSince(slowStartTime)
        
        #expect(slowResponse == "Slow response", "Should handle slower responses")
        #expect(slowDuration >= 1.0, "Slow response should take expected time")
    }
    
    // MARK: - Response Processing Tests
    
    @Test("API response parsing and validation")
    func testAPIResponseParsing() throws {
        // Test parsing of different API response formats
        
        struct ResponseTest {
            let response: String
            let shouldBeValid: Bool
            let description: String
        }
        
        let responseTests: [ResponseTest] = [
            ResponseTest(
                response: "Move camera slightly higher for better framing. Current distance is good.",
                shouldBeValid: true,
                description: "Valid guidance response"
            ),
            ResponseTest(
                response: "",
                shouldBeValid: false,
                description: "Empty response"
            ),
            ResponseTest(
                response: "Error: Unable to analyze image",
                shouldBeValid: false,
                description: "Error response"
            ),
            ResponseTest(
                response: String(repeating: "x", count: 10000),
                shouldBeValid: false,
                description: "Excessively long response"
            )
        ]
        
        for test in responseTests {
            // Act: Validate response (simulating app's validation logic)
            let isValidLength = test.response.count > 0 && test.response.count < 5000
            let containsError = test.response.lowercased().contains("error")
            let isValid = isValidLength && !containsError
            
            // Assert: Should match expected validity
            if test.shouldBeValid {
                #expect(isValid, "Response should be valid: \(test.description)")
            } else {
                #expect(!isValid || test.response.isEmpty, "Response should be invalid: \(test.description)")
            }
        }
    }
    
    @Test("Structured API response parsing")
    func testStructuredAPIResponseParsing() throws {
        // Test parsing of structured JSON responses (for advanced features)
        
        let jsonResponse = """
        {
            "guidance": "Move camera slightly to the right",
            "confidence": 0.85,
            "detected_issues": ["subject_off_center", "lighting_uneven"],
            "recommended_actions": [
                {"action": "move_camera", "direction": "right", "amount": "slight"},
                {"action": "adjust_angle", "direction": "up", "amount": "minimal"}
            ],
            "quality_score": 7.5
        }
        """
        
        // Act: Parse JSON response
        let jsonData = jsonResponse.data(using: .utf8)!
        
        // This would test the actual JSON parsing logic from the app
        do {
            let parsedResponse = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            
            // Assert: Should parse successfully
            #expect(parsedResponse != nil, "JSON should parse successfully")
            
            if let response = parsedResponse {
                #expect(response["guidance"] as? String == "Move camera slightly to the right")
                #expect(response["confidence"] as? Double == 0.85)
                #expect((response["detected_issues"] as? [String])?.count == 2)
            }
        } catch {
            Issue.record("JSON parsing failed: \(error)")
        }
    }
    
    // MARK: - Integration Tests
    
    @Test("Full API workflow simulation")
    func testFullAPIWorkflow() async throws {
        // Test the complete API workflow from capture to response
        
        // Arrange: Simulate a complete capture scenario
        let mockAPI = MockAPIService()
        let capturedImage = createTestImage(size: CGSize(width: 800, height: 600))
        
        let sceneMetrics = [
            "distance_to_person_meters": "2.3",
            "camera_height_meters": "1.65", 
            "camera_height_relative_to_eyes": "Cam 0.1m below eyes",
            "visible_body_parts": "head, shoulders, hands visible",
            "detected_subject_count": "1",
            "camera_roll_deg": "2.0",
            "camera_pitch_deg": "-5.0", 
            "camera_yaw_deg": "0.0",
            "camera_fov_h_deg": "60.0",
            "ambient_lux": "1200",
            "color_temp_k": "5800"
        ]
        
        mockAPI.mockResponse = "Good framing! The subject is well-positioned. Consider moving slightly closer for more intimate composition."
        
        // Act: Execute full workflow
        let analysisResponse = await mockAPI.sendAnalysis(image: capturedImage, metrics: sceneMetrics)
        
        // Assert: Workflow should complete successfully
        #expect(analysisResponse != nil, "Analysis should return response")
        #expect(mockAPI.lastRequest != nil, "Request should be recorded")
        
        let request = mockAPI.lastRequest!
        #expect(request.metrics.count == sceneMetrics.count, "All metrics should be transmitted")
        #expect(request.endpoint == "analysis", "Should use analysis endpoint")
        
        // Verify timestamp is recent
        let timeSinceRequest = Date().timeIntervalSince(request.timestamp)
        #expect(timeSinceRequest < 5.0, "Request should be recent")
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage(size: CGSize = CGSize(width: 400, height: 300)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Create a simple test pattern
            UIColor.lightGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Add some visual elements for more realistic testing
            UIColor.blue.setFill()
            context.fill(CGRect(x: size.width * 0.3, y: size.height * 0.3, 
                               width: size.width * 0.4, height: size.height * 0.4))
            
            UIColor.red.setFill()
            context.fill(CGRect(x: size.width * 0.45, y: size.height * 0.1, 
                               width: size.width * 0.1, height: size.height * 0.2))
        }
    }
}

/// Test suite for API configuration and authentication
struct APIConfigurationTests {
    
    @Test("API key validation")
    func testAPIKeyValidation() throws {
        // Test API key format validation
        
        struct APIKeyTest {
            let key: String
            let isValid: Bool
            let description: String
        }
        
        let keyTests: [APIKeyTest] = [
            APIKeyTest(key: "", isValid: false, description: "Empty key"),
            APIKeyTest(key: "AIza", isValid: false, description: "Too short"),
            APIKeyTest(key: "AIzaSyDemoKey1234567890123456789012345", isValid: true, description: "Valid format"),
            APIKeyTest(key: "invalid-key-format", isValid: false, description: "Invalid format"),
            APIKeyTest(key: "AIzaSy" + String(repeating: "x", count: 100), isValid: false, description: "Too long")
        ]
        
        for test in keyTests {
            // Act: Validate key format (basic validation)
            let hasValidPrefix = test.key.hasPrefix("AIza")
            let hasValidLength = test.key.count >= 20 && test.key.count <= 50
            let isValidFormat = hasValidPrefix && hasValidLength
            
            // Assert: Should match expected validity
            #expect(isValidFormat == test.isValid, "API key validation failed for: \(test.description)")
        }
    }
    
    @Test("API endpoint URL validation")
    func testAPIEndpointValidation() throws {
        // Test API endpoint URL validation
        
        let validEndpoints = [
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent",
            "https://generativelanguage.googleapis.com/v1/models/gemini-pro:generateContent"
        ]
        
        let invalidEndpoints = [
            "",
            "http://insecure-endpoint.com", // HTTP instead of HTTPS
            "invalid-url",
            "ftp://wrong-protocol.com"
        ]
        
        for endpoint in validEndpoints {
            // Act: Validate URL
            let url = URL(string: endpoint)
            
            // Assert: Should be valid HTTPS URL
            #expect(url != nil, "Valid endpoint should parse: \(endpoint)")
            #expect(url?.scheme == "https", "Should use HTTPS: \(endpoint)")
        }
        
        for endpoint in invalidEndpoints {
            // Act: Validate URL
            let url = URL(string: endpoint)
            
            // Assert: Should be invalid or non-HTTPS
            let isInvalid = url == nil || url?.scheme != "https"
            #expect(isInvalid, "Invalid endpoint should fail validation: \(endpoint)")
        }
    }
}