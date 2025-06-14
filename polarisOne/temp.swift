// ⏺ Update(polarisOne/ARKitCameraApp.swift)
//   ⎿  Updated polarisOne/ARKitCameraApp.swift with 3 additions and 54 removals
//      1111      @ObservedObject var viewModel: ARViewModel
//      1112 
//      1113      var body: some View {
//      1114          GeometryReader { geometry in
//      1115              ZStack {
//      1116                  // Dynamic target framing box that shows where camera should be positioned
//      1117                  if viewModel.isGuidanceActive && viewModel.guidanceTargetScreenBounds != .zero {
//      1118                      // Draw the target framing box with dynamic color based on alignment
//      1119                      RoundedRectangle(cornerRadius: 16)
//      1120                          .stroke(lineWidth: 4)
//      1121                          .foregroundColor(colorForAlignment(viewModel.guidanceAlignmentScore))
//      1122                          .frame(width: viewModel.guidanceTargetScreenBounds.width,
//      1123                                 height: viewModel.guidanceTargetScreenBounds.height)
//      1124                          .position(x: viewModel.guidanceTargetScreenBounds.midX,
//      1125                                    y: viewModel.guidanceTargetScreenBounds.midY)
//      1126                          .shadow(color: .black.opacity(0.3), radius: 2)
//      1127                      
//      1128                      // Corner indicators for better visibility
//      1129                      let corners = [
//      1130                          CGPoint(x: viewModel.guidanceTargetScreenBounds.minX, y: viewModel.guidanceTargetScreenBounds.minY),
//      1131                          CGPoint(x: viewModel.guidanceTargetScreenBounds.maxX, y: viewModel.guidanceTargetScreenBounds.minY),
//      1132                          CGPoint(x: viewModel.guidanceTargetScreenBounds.maxX, y: viewModel.guidanceTargetScreenBounds.maxY),
//      1133                          CGPoint(x: viewModel.guidanceTargetScreenBounds.minX, y: viewModel.guidanceTargetScreenBounds.maxY)
//      1134                      ]
//      1135                      
//      1136                      ForEach(0..<4) { index in
//      1137                          Circle()
//      1138                              .fill(colorForAlignment(viewModel.guidanceAlignmentScore))
//      1139                              .frame(width: 12, height: 12)
//      1140                              .position(corners[index])
//      1141                              .shadow(radius: 2)
//      1142                      }
//      1143                      
//      1144                      // Directional indicators showing camera movement needed
//      1145                      DirectionalArrows(directions: viewModel.guidanceDirections,
//      1146                                        screenSize: geometry.size,
//      1147                                        targetBounds: viewModel.guidanceTargetScreenBounds)
//      1148                      
//      1149                      // Subject indicator (shows current subject position)
//      1150                      if viewModel.guidanceSubjectScreenBounds != .zero {
//      1151                          SubjectPositionIndicator(subjectBounds: viewModel.guidanceSubjectScreenBounds,
//      1152                                                   isAligned: viewModel.guidanceAlignmentScore > 0.8)
//      1153                      }
//      1154                  }
//      1155              }
//      1156          }
//      1157          .allowsHitTesting(false)  // Don't block touch events
//      1114          // Use the new Apple-style alignment view
//      1115          AppleStyleAlignmentView(viewModel: viewModel)
//      1116              .allowsHitTesting(false)  // Don't block touch events
//      1117      }
//      1118      
//      1119      func colorForAlignment(_ score: Float) -> Color {
//      1120          if score < 0.3 {
//      1121              return .red
//      1122          } else if score < 0.7 {
//      1123              return .yellow
//      1124          } else {
//      1125              return .green
//      1126          }
//      1127      }
//      1118  }
//      1119 