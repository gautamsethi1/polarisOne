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
        "generationConfig": [
            "thinkingConfig": [
                "thinkingBudget": 0
            ]
        ]
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
        "contents": [["parts": partsArray]],
        "generationConfig": [
            "thinkingConfig": [
                "thinkingBudget": 0
            ]
        ]
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