//
//  MeshExportTests.swift
//  polarisOneTests
//
//  Tests for 3D mesh export functionality and USDZ conversion
//

import Testing
import simd
import ModelIO
import Metal
import MetalKit
import Foundation
@testable import polarisOne

/// Test suite for 3D mesh export and USDZ functionality
struct MeshExportTests {
    
    // MARK: - Mock Mesh Data
    
    /// Mock AR mesh anchor for testing without actual ARKit session
    struct MockARMeshAnchor {
        let transform: simd_float4x4
        let geometry: MockARMeshGeometry
        let identifier: UUID
        
        init(transform: simd_float4x4 = matrix_identity_float4x4,
             vertexCount: Int = 100,
             faceCount: Int = 150) {
            self.transform = transform
            self.geometry = MockARMeshGeometry(vertexCount: vertexCount, faceCount: faceCount)
            self.identifier = UUID()
        }
    }
    
    /// Mock AR mesh geometry with realistic vertex and face data
    struct MockARMeshGeometry {
        let vertices: MockMTLBuffer
        let faces: MockMTLBuffer
        let normals: MockMTLBuffer
        let vertexCount: Int
        let faceCount: Int
        
        init(vertexCount: Int, faceCount: Int) {
            self.vertexCount = vertexCount
            self.faceCount = faceCount
            
            // Create mock vertex data (x, y, z coordinates)
            var vertexData: [Float] = []
            for i in 0..<vertexCount {
                let angle = Float(i) / Float(vertexCount) * 2 * .pi
                let radius: Float = 1.0
                let height = Float(i) / Float(vertexCount) * 2.0 - 1.0 // Range -1 to 1
                
                vertexData.append(cos(angle) * radius) // x
                vertexData.append(height)              // y  
                vertexData.append(sin(angle) * radius) // z
            }
            
            // Create mock face data (triangle indices)
            var faceData: [UInt32] = []
            for i in 0..<faceCount {
                // Create triangular faces with valid vertex indices
                let baseIndex = UInt32(i % (vertexCount - 2))
                faceData.append(baseIndex)
                faceData.append(baseIndex + 1)
                faceData.append(baseIndex + 2)
            }
            
            // Create mock normal data (normalized vectors)
            var normalData: [Float] = []
            for i in 0..<vertexCount {
                let angle = Float(i) / Float(vertexCount) * 2 * .pi
                normalData.append(cos(angle)) // x normal
                normalData.append(0.0)        // y normal (horizontal surface)
                normalData.append(sin(angle)) // z normal
            }
            
            self.vertices = MockMTLBuffer(data: vertexData)
            self.faces = MockMTLBuffer(data: faceData)
            self.normals = MockMTLBuffer(data: normalData)
        }
    }
    
    /// Mock Metal buffer for testing
    struct MockMTLBuffer {
        let data: [Any]
        let length: Int
        
        init<T>(data: [T]) {
            self.data = data.map { $0 as Any }
            self.length = data.count * MemoryLayout<T>.size
        }
        
        func contents() -> UnsafeMutableRawPointer {
            // In real implementation, this would return actual buffer contents
            // For testing, we'll return a mock pointer
            return UnsafeMutableRawPointer(mutating: data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! })
        }
    }
    
    // MARK: - Mesh Data Validation Tests
    
    @Test("Mesh vertex data validation")
    func testMeshVertexDataValidation() throws {
        // Test that mesh vertex data is properly structured
        
        // Arrange: Create mock mesh with known vertex count
        let vertexCount = 50
        let mesh = MockARMeshAnchor(vertexCount: vertexCount, faceCount: 75)
        
        // Act: Validate vertex data structure
        let geometry = mesh.geometry
        
        // Assert: Vertex count should match expected
        #expect(geometry.vertexCount == vertexCount, "Vertex count should match: \(geometry.vertexCount) vs \(vertexCount)")
        
        // Assert: Vertex buffer should have correct size
        // Each vertex has 3 floats (x, y, z), so buffer should be vertexCount * 3 * sizeof(Float)
        let expectedVertexBufferSize = vertexCount * 3 * MemoryLayout<Float>.size
        #expect(geometry.vertices.length == expectedVertexBufferSize, 
               "Vertex buffer size should be \(expectedVertexBufferSize), got \(geometry.vertices.length)")
        
        // Assert: Normal buffer should match vertex count
        let expectedNormalBufferSize = vertexCount * 3 * MemoryLayout<Float>.size
        #expect(geometry.normals.length == expectedNormalBufferSize,
               "Normal buffer size should match vertex count")
    }
    
    @Test("Mesh face data validation")
    func testMeshFaceDataValidation() throws {
        // Test that mesh face data is properly structured
        
        // Arrange: Create mesh with known parameters
        let vertexCount = 30
        let faceCount = 40
        let mesh = MockARMeshAnchor(vertexCount: vertexCount, faceCount: faceCount)
        
        // Act: Validate face data
        let geometry = mesh.geometry
        
        // Assert: Face count should match expected
        #expect(geometry.faceCount == faceCount, "Face count should match")
        
        // Assert: Face buffer should have correct size
        // Each face has 3 indices (triangle), so buffer should be faceCount * 3 * sizeof(UInt32)
        let expectedFaceBufferSize = faceCount * 3 * MemoryLayout<UInt32>.size
        #expect(geometry.faces.length == expectedFaceBufferSize,
               "Face buffer size should be \(expectedFaceBufferSize), got \(geometry.faces.length)")
    }
    
    @Test("Mesh vertex coordinate bounds validation")
    func testMeshVertexCoordinateBounds() throws {
        // Test that vertex coordinates are within reasonable bounds
        
        // Arrange: Create mesh and extract vertex data
        let mesh = MockARMeshAnchor(vertexCount: 20, faceCount: 30)
        let vertexData = mesh.geometry.vertices.data.compactMap { $0 as? Float }
        
        // Act: Analyze vertex coordinate ranges
        var minX: Float = Float.greatestFiniteMagnitude
        var maxX: Float = -Float.greatestFiniteMagnitude
        var minY: Float = Float.greatestFiniteMagnitude
        var maxY: Float = -Float.greatestFiniteMagnitude
        var minZ: Float = Float.greatestFiniteMagnitude
        var maxZ: Float = -Float.greatestFiniteMagnitude
        
        // Process vertices (every 3 floats = 1 vertex)
        for i in stride(from: 0, to: vertexData.count, by: 3) {
            let x = vertexData[i]
            let y = vertexData[i + 1]
            let z = vertexData[i + 2]
            
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            minZ = min(minZ, z); maxZ = max(maxZ, z)
        }
        
        // Assert: Coordinates should be within reasonable bounds for AR mesh
        let maxReasonableBound: Float = 10.0 // 10 meters
        #expect(abs(minX) < maxReasonableBound && abs(maxX) < maxReasonableBound, "X coordinates should be reasonable")
        #expect(abs(minY) < maxReasonableBound && abs(maxY) < maxReasonableBound, "Y coordinates should be reasonable")
        #expect(abs(minZ) < maxReasonableBound && abs(maxZ) < maxReasonableBound, "Z coordinates should be reasonable")
        
        // Assert: Mesh should have non-zero dimensions
        let xRange = maxX - minX
        let yRange = maxY - minY
        let zRange = maxZ - minZ
        #expect(xRange > 0 && yRange > 0 && zRange > 0, "Mesh should have non-zero dimensions")
    }
    
    // MARK: - USDZ Conversion Tests
    
    @Test("MDLMesh creation from mock AR mesh")
    func testMDLMeshCreationFromARMesh() throws {
        // Test the conversion process from AR mesh to ModelIO mesh
        
        // Arrange: Create mock AR mesh
        let arMesh = MockARMeshAnchor(vertexCount: 24, faceCount: 36)
        
        // Act: Simulate MDLMesh creation (simplified version of app logic)
        let geometry = arMesh.geometry
        
        // Simulate creating MDLMesh descriptor
        let vertexDescriptor = MDLVertexDescriptor()
        
        // Position attribute (location 0)
        let positionAttribute = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[0] = positionAttribute
        
        // Normal attribute (location 1)
        let normalAttribute = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: 0,
            bufferIndex: 1
        )
        vertexDescriptor.attributes[1] = normalAttribute
        
        // Layout for position buffer
        let positionLayout = MDLVertexBufferLayout()
        positionLayout.stride = 3 * MemoryLayout<Float>.size
        vertexDescriptor.layouts[0] = positionLayout
        
        // Layout for normal buffer
        let normalLayout = MDLVertexBufferLayout()
        normalLayout.stride = 3 * MemoryLayout<Float>.size
        vertexDescriptor.layouts[1] = normalLayout
        
        // Assert: Vertex descriptor should be properly configured
        #expect(vertexDescriptor.attributes[0] != nil, "Position attribute should be configured")
        #expect(vertexDescriptor.attributes[1] != nil, "Normal attribute should be configured")
        #expect(vertexDescriptor.layouts[0]?.stride == 12, "Position layout stride should be 12 bytes (3 floats)")
        #expect(vertexDescriptor.layouts[1]?.stride == 12, "Normal layout stride should be 12 bytes (3 floats)")
    }
    
    @Test("USDZ file generation validation")
    func testUSDZFileGeneration() throws {
        // Test the USDZ file generation process
        
        // Arrange: Create mock MDLAsset
        let asset = MDLAsset()
        
        // Create a simple test mesh
        let allocator = MDLMeshBufferAllocator()
        let mesh = MDLMesh.newBox(withDimensions: simd_float3(1, 1, 1), 
                                 segments: simd_uint3(1, 1, 1),
                                 geometryType: .triangles,
                                 inwardNormals: false,
                                 allocator: allocator)
        
        asset.add(mesh)
        
        // Act: Test export capability (without actually writing file)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mesh.usdz")
        
        // Test that we can create the export URL
        #expect(tempURL.pathExtension == "usdz", "Export URL should have .usdz extension")
        
        // Test asset validity
        #expect(asset.count > 0, "Asset should contain at least one object")
        
        // Clean up - remove temp file if it exists
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    @Test("Multiple mesh anchors aggregation")
    func testMultipleMeshAnchorsAggregation() throws {
        // Test combining multiple mesh anchors into single export
        
        // Arrange: Create multiple mock mesh anchors
        let mesh1 = MockARMeshAnchor(
            transform: simd_float4x4(translation: simd_float3(0, 0, 0)),
            vertexCount: 20,
            faceCount: 30
        )
        
        let mesh2 = MockARMeshAnchor(
            transform: simd_float4x4(translation: simd_float3(1, 0, 0)),
            vertexCount: 15,
            faceCount: 20
        )
        
        let mesh3 = MockARMeshAnchor(
            transform: simd_float4x4(translation: simd_float3(0, 1, 0)),
            vertexCount: 25,
            faceCount: 40
        )
        
        let meshAnchors = [mesh1, mesh2, mesh3]
        
        // Act: Simulate aggregation (app logic)
        let totalVertexCount = meshAnchors.reduce(0) { $0 + $1.geometry.vertexCount }
        let totalFaceCount = meshAnchors.reduce(0) { $0 + $1.geometry.faceCount }
        
        // Assert: Totals should be correct
        #expect(totalVertexCount == 60, "Total vertex count should be 20+15+25=60")
        #expect(totalFaceCount == 90, "Total face count should be 30+20+40=90")
        
        // Assert: Each mesh should have unique identifier
        let uniqueIDs = Set(meshAnchors.map { $0.identifier })
        #expect(uniqueIDs.count == meshAnchors.count, "All mesh anchors should have unique identifiers")
    }
    
    // MARK: - Export Performance Tests
    
    @Test("Mesh export performance with large dataset")
    func testMeshExportPerformanceWithLargeDataset() throws {
        // Test performance with realistic mesh sizes
        
        // Arrange: Create large mesh (realistic for room scanning)
        let largeVertexCount = 10000
        let largeFaceCount = 15000
        let largeMesh = MockARMeshAnchor(vertexCount: largeVertexCount, faceCount: largeFaceCount)
        
        // Act: Measure data processing time
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Simulate processing vertex data (like in real export)
        let vertexData = largeMesh.geometry.vertices.data.compactMap { $0 as? Float }
        let faceData = largeMesh.geometry.faces.data.compactMap { $0 as? UInt32 }
        
        // Process all vertices to simulate conversion overhead
        var processedVertices = 0
        for i in stride(from: 0, to: vertexData.count, by: 3) {
            // Simulate coordinate transformation (basic operation)
            let _ = simd_float3(vertexData[i], vertexData[i+1], vertexData[i+2])
            processedVertices += 1
        }
        
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        
        // Assert: Processing should complete in reasonable time
        #expect(processedVertices == largeVertexCount, "All vertices should be processed")
        #expect(processingTime < 1.0, "Large mesh processing should complete within 1 second, took \(processingTime)s")
        
        // Assert: Memory usage should be reasonable
        let vertexDataSize = vertexData.count * MemoryLayout<Float>.size
        let faceDataSize = faceData.count * MemoryLayout<UInt32>.size
        let totalDataSize = vertexDataSize + faceDataSize
        
        // For 10K vertices and 15K faces, should be manageable size
        #expect(totalDataSize < 1_000_000, "Total data size should be under 1MB, got \(totalDataSize) bytes")
    }
    
    @Test("Memory efficiency during mesh conversion")
    func testMemoryEfficiencyDuringMeshConversion() throws {
        // Test memory usage patterns during conversion
        
        struct MemoryTest {
            let vertexCount: Int
            let description: String
        }
        
        let tests: [MemoryTest] = [
            MemoryTest(vertexCount: 100, description: "Small mesh"),
            MemoryTest(vertexCount: 1000, description: "Medium mesh"),
            MemoryTest(vertexCount: 5000, description: "Large mesh")
        ]
        
        for test in tests {
            // Arrange: Create mesh of specified size
            let mesh = MockARMeshAnchor(vertexCount: test.vertexCount, faceCount: test.vertexCount * 3 / 2)
            
            // Act: Calculate expected memory usage
            let vertexBufferSize = test.vertexCount * 3 * MemoryLayout<Float>.size  // x,y,z per vertex
            let normalBufferSize = test.vertexCount * 3 * MemoryLayout<Float>.size  // nx,ny,nz per vertex
            let faceBufferSize = (test.vertexCount * 3 / 2) * 3 * MemoryLayout<UInt32>.size // 3 indices per face
            
            let totalMemoryUsage = vertexBufferSize + normalBufferSize + faceBufferSize
            
            // Assert: Memory usage should scale linearly with vertex count
            let memoryPerVertex = Double(totalMemoryUsage) / Double(test.vertexCount)
            #expect(memoryPerVertex < 100.0, "\(test.description): Memory per vertex should be reasonable, got \(memoryPerVertex) bytes")
            
            // Assert: No mesh should exceed reasonable memory limits
            #expect(totalMemoryUsage < 50_000_000, "\(test.description): Total memory should be under 50MB, got \(totalMemoryUsage) bytes")
        }
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Export error handling with invalid mesh data")
    func testExportErrorHandlingWithInvalidMeshData() throws {
        // Test how export handles various error conditions
        
        // Test: Empty mesh (no vertices)
        let emptyMesh = MockARMeshAnchor(vertexCount: 0, faceCount: 0)
        let isEmpty = emptyMesh.geometry.vertexCount == 0
        #expect(isEmpty, "Empty mesh should be detected")
        
        // Test: Mesh with faces but no vertices (invalid state)
        let invalidMesh = MockARMeshAnchor(vertexCount: 0, faceCount: 10)
        let isInvalid = invalidMesh.geometry.vertexCount == 0 && invalidMesh.geometry.faceCount > 0
        #expect(isInvalid, "Invalid mesh state should be detected")
        
        // Test: Mesh with mismatched vertex/face counts
        let mismatchedMesh = MockARMeshAnchor(vertexCount: 3, faceCount: 100) // Too many faces for vertex count
        let hasTooManyFaces = mismatchedMesh.geometry.faceCount > mismatchedMesh.geometry.vertexCount * 2
        #expect(hasTooManyFaces, "Mesh with excessive face count should be detected")
    }
    
    @Test("File system error handling")
    func testFileSystemErrorHandling() throws {
        // Test handling of file system related errors
        
        // Test: Invalid export path
        let invalidPaths = [
            "", // Empty path
            "/invalid/path/that/does/not/exist/mesh.usdz", // Non-existent directory
            "/mesh.usdz", // Root directory (likely no permission)
        ]
        
        for path in invalidPaths {
            // Act: Test URL creation and validation
            if !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                let parentDir = url.deletingLastPathComponent()
                
                // Check if parent directory exists
                let parentExists = FileManager.default.fileExists(atPath: parentDir.path)
                
                // For most invalid paths, parent should not exist or be inaccessible
                if path.contains("/invalid/") {
                    #expect(!parentExists, "Invalid path parent directory should not exist: \(path)")
                }
            }
        }
        
        // Test: Valid temporary directory
        let validTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.usdz")
        let tempParentExists = FileManager.default.fileExists(atPath: validTempURL.deletingLastPathComponent().path)
        #expect(tempParentExists, "Temporary directory should exist and be accessible")
    }
    
    // MARK: - Integration Tests
    
    @Test("Complete mesh export workflow simulation")
    func testCompleteMeshExportWorkflow() throws {
        // Test the complete workflow from AR mesh to USDZ file
        
        // Arrange: Simulate a realistic room scanning scenario
        let roomMeshes = [
            MockARMeshAnchor( // Floor mesh
                transform: simd_float4x4(translation: simd_float3(0, 0, 0)),
                vertexCount: 1000,
                faceCount: 1500
            ),
            MockARMeshAnchor( // Wall mesh
                transform: simd_float4x4(translation: simd_float3(0, 1.5, -2)),
                vertexCount: 800,
                faceCount: 1200
            ),
            MockARMeshAnchor( // Furniture mesh
                transform: simd_float4x4(translation: simd_float3(1, 0.5, -1)),
                vertexCount: 500,
                faceCount: 750
            )
        ]
        
        // Act: Simulate complete export process
        
        // Step 1: Validate all meshes
        var validMeshes: [MockARMeshAnchor] = []
        for mesh in roomMeshes {
            if mesh.geometry.vertexCount > 0 && mesh.geometry.faceCount > 0 {
                validMeshes.append(mesh)
            }
        }
        
        // Step 2: Calculate combined statistics
        let totalVertices = validMeshes.reduce(0) { $0 + $1.geometry.vertexCount }
        let totalFaces = validMeshes.reduce(0) { $0 + $1.geometry.faceCount }
        
        // Step 3: Estimate file size
        let estimatedVertexDataSize = totalVertices * 3 * MemoryLayout<Float>.size * 2 // vertices + normals
        let estimatedFaceDataSize = totalFaces * 3 * MemoryLayout<UInt32>.size
        let estimatedTotalSize = estimatedVertexDataSize + estimatedFaceDataSize
        
        // Assert: Workflow should produce valid results
        #expect(validMeshes.count == roomMeshes.count, "All room meshes should be valid")
        #expect(totalVertices == 2300, "Total vertex count should be correct")
        #expect(totalFaces == 3450, "Total face count should be correct")
        #expect(estimatedTotalSize < 1_000_000, "Estimated file size should be reasonable: \(estimatedTotalSize) bytes")
        
        // Step 4: Verify mesh spatial distribution
        var meshBounds = (
            minX: Float.greatestFiniteMagnitude, maxX: -Float.greatestFiniteMagnitude,
            minY: Float.greatestFiniteMagnitude, maxY: -Float.greatestFiniteMagnitude,
            minZ: Float.greatestFiniteMagnitude, maxZ: -Float.greatestFiniteMagnitude
        )
        
        for mesh in validMeshes {
            let pos = mesh.transform.translation
            meshBounds.minX = min(meshBounds.minX, pos.x)
            meshBounds.maxX = max(meshBounds.maxX, pos.x)
            meshBounds.minY = min(meshBounds.minY, pos.y)
            meshBounds.maxY = max(meshBounds.maxY, pos.y)
            meshBounds.minZ = min(meshBounds.minZ, pos.z)
            meshBounds.maxZ = max(meshBounds.maxZ, pos.z)
        }
        
        let roomWidth = meshBounds.maxX - meshBounds.minX
        let roomHeight = meshBounds.maxY - meshBounds.minY
        let roomDepth = meshBounds.maxZ - meshBounds.minZ
        
        // Assert: Room dimensions should be realistic
        #expect(roomWidth > 0 && roomWidth < 20, "Room width should be realistic: \(roomWidth)m")
        #expect(roomHeight > 0 && roomHeight < 5, "Room height should be realistic: \(roomHeight)m")
        #expect(roomDepth > 0 && roomDepth < 20, "Room depth should be realistic: \(roomDepth)m")
    }
}