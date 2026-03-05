//
//  PreviewView.swift
//  3D-Kankl-Druck-Editor
//
//  SceneKit 3D preview wrapped for SwiftUI. Supports rotate/zoom via gestures.
//

import SwiftUI
import SceneKit

struct PreviewView: UIViewRepresentable {
    let geometry: SCNGeometry

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true  // built-in rotate/pinch/pan
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .systemGroupedBackground

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 20, 60)
        cameraNode.look(at: SCNVector3Zero)
        scnView.scene?.rootNode.addChildNode(cameraNode)

        // Shape node
        let shapeNode = SCNNode(geometry: geometry)
        shapeNode.name = "shape"
        scnView.scene?.rootNode.addChildNode(shapeNode)

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        // Replace geometry on the existing shape node to keep camera position
        if let shapeNode = scnView.scene?.rootNode.childNode(withName: "shape", recursively: false) {
            shapeNode.geometry = geometry
        }
    }
}
