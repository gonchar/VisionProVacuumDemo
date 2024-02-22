//
//  RotateSystem.swift
//  VacuumDemo
//
//  Created by Sergey Gonchar on 11/02/2024.
//

import Foundation
import RealityKit

class RotateSystem: System {
  static let query = EntityQuery(where: .has(RotateComponent.self))
  
  required init(scene: Scene) {
  }
  
  func update(context: SceneUpdateContext) {
    let results = context.entities(matching: Self.query, updatingSystemWhen: .rendering)
    
    var entitiesToRemove:[Entity] = []
    
    for result in results {
      if var component = result.components[RotateComponent.self] {
        let speedMultiplier:Float = component.isCollecting ? 10.0 : 1.0
        
        result.orientation = result.orientation * simd_quatf(angle: speedMultiplier * Float(context.deltaTime), axis: .init(x: 0.0, y: 1.0, z: 0.0))
        
        if component.isCollecting {
          let progress = component.animationProgress + (1.0 - component.animationProgress) * 0.1
          component.animationProgress = progress
          
          result.components.set(OpacityComponent(opacity: 1.0 - progress))
          
          if component.startPosY == nil {
            result.components.remove(CollisionComponent.self)
            component.startPosY = result.position.y
            component.endPosY = result.position.y + 0.2
          }
          
          if let startPosY = component.startPosY,
             let endPosY = component.endPosY {
            result.position.y = startPosY + (endPosY - startPosY) * progress
          }
          
          result.components.set(component)
          
          if progress > 0.999 {
            entitiesToRemove.append(result)
          }
        }
      }
    }
    
    for entity in entitiesToRemove {
      entity.components.remove(RotateComponent.self)
      entity.removeFromParent()
    }
  }
}
