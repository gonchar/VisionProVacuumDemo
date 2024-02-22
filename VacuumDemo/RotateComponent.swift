//
//  RotateComponent.swift
//  VacuumDemo
//
//  Created by Sergey Gonchar on 11/02/2024.
//

import Foundation
import RealityKit

struct RotateComponent: Component {
  var isCollecting:Bool = false
  var animationProgress:Float = 0.0
  
  var startPosY:Float?
  var endPosY:Float?
}


