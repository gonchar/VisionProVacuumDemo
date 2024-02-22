//
//  ImmersiveView.swift
//  VacuumDemo
//
//  Created by Sergey Gonchar on 11/02/2024.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ImmersiveView: View {
  @StateObject var realityKitSceneController:VacuumRealityController = VacuumRealityController()
  
  var body: some View {
    RealityView { content, attachments in
      await realityKitSceneController.firstInit(&content, attachments: attachments)
    } update: { content, attachments in
      realityKitSceneController.updateView(&content, attachments: attachments)
    } placeholder: {
      ProgressView()
    } attachments: {
      let _ = print("--attachments")
      Attachment(id: "score") {
        Text("\(realityKitSceneController.score)")
          .font(.system(size: 100))
          .foregroundColor(.white)
          .fontWeight(.bold)
      }
    }
    .gesture(SpatialTapGesture()
      .targetedToAnyEntity()
      .onEnded({ targetValue in
        realityKitSceneController.onTapSpatial(targetValue)
      })
    )
    .onAppear {
      // Appear happens before realitkit scene controller init
    }
    .onDisappear {
      realityKitSceneController.cleanup()
    }
  }
}
