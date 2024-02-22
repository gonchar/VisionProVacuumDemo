//
//  VacuumDemoApp.swift
//  VacuumDemo
//
//  Created by Sergey Gonchar on 11/02/2024.
//

import SwiftUI

@main
struct VacuumDemoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    
    ImmersiveSpace(id: "ImmersiveSpace") {
      ImmersiveView()
    }
  }
  
  init() {
#if DEBUG
    Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/xrOSInjection.bundle")?.load()
#endif
  }
}
