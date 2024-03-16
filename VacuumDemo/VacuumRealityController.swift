//
//  VacuumRealityController.swift
//  VacuumDemo
//
//  Created by Sergey Gonchar on 11/02/2024.
//

import Foundation
import SwiftUI
import RealityKit
import RealityKitContent
import Combine
import ARKit

@MainActor
protocol SceneControllerProtocol {
  func firstInit(_ content : inout RealityViewContent, attachments: RealityViewAttachments) async
  func updateView(_ content : inout RealityViewContent, attachments: RealityViewAttachments)
  func cleanup()
  func onTapSpatial(_ targetValue: EntityTargetValue<SpatialTapGesture.Value>)
  init()
}

@MainActor
final class VacuumRealityController: ObservableObject {
  
  @Published var score:Int = 0
  
  struct CoinPlacement {
    var position:SIMD3<Float>
  }
  
  struct Triangle {
    let positions: [SIMD3<Float>]
  }
  
  private var cancellabe:AnyCancellable?;
  
  private lazy var controllerRoot:Entity = {
    var result = Entity()
    result.name = "controllerRoot"
    return result
  }()
  
  private var mainScene:Entity?
  
  private var worldTracking = WorldTrackingProvider()
  private var handTracking = HandTrackingProvider()
  private var sceneReconstruction = SceneReconstructionProvider(modes: [.classification])
  private var session = ARKitSession()
  
  private var meshEntities = [UUID: ModelEntity]()
  
  private var coinsGrid: [String: Bool] = [:]
  private var coins: [String: SIMD3<Float>] = [:]
  
  private var coinModel:Entity?
  private var part1Model:Entity?
  private var part2Model:Entity?
  private var part2Connector:Entity?
  private var scoreEntity:Entity?
  
  private var coinEntities: [String:Entity] = [:]
  
  private var coinCollisionGroup = CollisionGroup(rawValue: 1 << 0)
  private var vacuumCollisionGroup = CollisionGroup(rawValue: 1 << 1)
  
  private var coinSound:AudioFileResource?
  private var vacuumSoundController:AudioPlaybackController?
  
  private var isVacuumOn:Bool = false
    
  private var setupTask:Task<Void, Error>? = nil
  private var updateTask:Task<Void, Never>? = nil
  
  init() {
  }
  
  public func cleanup() {
    setupTask?.cancel()
    updateTask?.cancel()

    cancellabe?.cancel()
    cancellabe = nil
    mainScene = nil
  }
  
  public func firstInit(_ content : inout RealityViewContent, attachments: RealityViewAttachments) async {
    RotateSystem.registerSystem()
    RotateComponent.registerComponent()
    
    cancellabe = NotificationCenter.default.publisher(for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"))
      .sink { _ in
        Task { @MainActor in
          self.updateAfterInject()
        }
      }
    
    content.add(controllerRoot)
    
    if let scoreAttachment = attachments.entity(for: "score") {
      scoreEntity = scoreAttachment
      controllerRoot.addChild(scoreAttachment)
    }
    
    _ = content.subscribe(to: SceneEvents.Update.self, on: nil) { event in
      self.updateFrame(event)
    }
    
    _ = content.subscribe(to: CollisionEvents.Began.self, on: nil, self.onCollisionBegan)
    
    setupTask = Task {
      do {
        try await session.run([worldTracking, handTracking, sceneReconstruction])
      } catch {
        print("Error Can't start ARKit \(error)")
      }
    }
    
    updateTask = Task {
      for await update in sceneReconstruction.anchorUpdates {
        let meshAnchor = update.anchor
        
        guard let shape = try? await ShapeResource.generateStaticMesh(from: meshAnchor) else { continue }
        
        switch update.event {
          case .added:
            let entity = ModelEntity()
            entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
            entity.collision = CollisionComponent(shapes: [shape], isStatic: true)
            entity.collision?.filter.group = .sceneUnderstanding
            
            if let classes = getClasses(meshAnchor: meshAnchor),
              let meshResource = getMeshResourceFromAnchor(meshAnchor: meshAnchor) {
              let modelComponent = ModelComponent(mesh: meshResource, materials: [OcclusionMaterial()])
              entity.components.set(modelComponent)
              updateCoinGrid(meshAnchor: meshAnchor, classes: classes)
            }
            meshEntities[meshAnchor.id] = entity
            controllerRoot.addChild(entity)
          case .updated:
            guard let entity = meshEntities[meshAnchor.id] else { continue }
            entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
            entity.collision = CollisionComponent(shapes: [shape], isStatic: true)
            entity.collision?.filter.group = .sceneUnderstanding
            
            if let classes = getClasses(meshAnchor: meshAnchor),
              let meshResource = getMeshResourceFromAnchor(meshAnchor: meshAnchor) {
              let modelComponent = ModelComponent(mesh: meshResource, materials: [OcclusionMaterial()])
              entity.components.set(modelComponent)
              updateCoinGrid(meshAnchor: meshAnchor, classes: classes)
            }
            
          case .removed:
            meshEntities[meshAnchor.id]?.removeFromParent()
            meshEntities.removeValue(forKey: meshAnchor.id)
        }
      }
    }
    
    let headContainer = Entity()
    headContainer.name = "headContainer"
    controllerRoot.addChild(headContainer)
    
    await setupSceneFirstTime()
  }
  
  private func onCollisionBegan(event: CollisionEvents.Began) {
    if event.entityA.name == "coin" {
      event.entityA.components[RotateComponent.self]?.isCollecting = true
      //play sound
      if let coinSound = coinSound {
        event.entityA.playAudio(coinSound)
      }
      //increase score
      score += 1
    }
  }
  
  private func updateCoinGrid(meshAnchor: MeshAnchor, classes: [UInt8]) {
    guard meshAnchor.geometry.faces.primitive == .triangle,
          meshAnchor.geometry.vertices.format == .float3,
          let indexArray = getIndexArray(meshAnchor: meshAnchor) else {
      return
    }
    
    let positions = readFloat3FromMTL(source: meshAnchor.geometry.vertices)
    
    var triangles:[Triangle] = []
    
    for faceId in 0 ..< meshAnchor.geometry.faces.count {
      let classId = classes[faceId]
      if classId == 2 {
        let v0:Int = Int(indexArray[faceId * 3])
        let v1:Int = Int(indexArray[faceId * 3 + 1])
        let v2:Int = Int(indexArray[faceId * 3 + 2])
        
        let points:[SIMD3<Float>] = [positions[v0], positions[v1], positions[v2]]
        
        let transformed = points.map { input in
          let result4:SIMD4<Float> = meshAnchor.originFromAnchorTransform * simd_float4(input, 1.0)
          return SIMD3<Float>(x: result4.x, y: result4.y, z: result4.z)
        }
        
        triangles.append(.init(positions: transformed))
      }
    }
    
    // create coins
    let cellSize: Float = 0.4
    
    for triangle in triangles {
      let bounds = triangleBoundingBox(of: triangle)
      
      let gridX = Int(bounds.minX / cellSize)
      let gridY = Int(bounds.minY / cellSize)
      let gridZ = Int(bounds.minZ / cellSize)
      
      let key = "\(gridX),\(gridY),\(gridZ)"
      
      if coinsGrid[key] == nil {
        coinsGrid[key] = true
        let trianglePosY = bounds.minY + (bounds.maxY - bounds.minY) / 2.0
        coins[key] = SIMD3<Float>(Float(gridX) * cellSize, trianglePosY, Float(gridZ) * cellSize)
      }
    }
  }
  
  private func triangleBoundingBox(of triangle: Triangle) -> (minX: Float, minY: Float, minZ: Float, maxX: Float, maxY: Float, maxZ: Float) {
    var minX = Float.infinity
    var minY = Float.infinity
    var minZ = Float.infinity
    
    var maxX = -Float.infinity
    var maxY = -Float.infinity
    var maxZ = -Float.infinity
    
    for point in triangle.positions {
      minX = min(minX, point.x)
      minY = min(minY, point.y)
      minZ = min(minZ, point.z)
      maxX = max(maxX, point.x)
      maxY = max(maxY, point.y)
      maxZ = max(maxZ, point.z)
    }
    
    return (minX, minY, minZ, maxX, maxY, maxZ)
  }
  
  private func getClasses(meshAnchor: MeshAnchor) -> [UInt8]? {
    guard let classifications = meshAnchor.geometry.classifications,
          classifications.format == .uchar else { return nil }
    
    let classBuffer = classifications.buffer.contents()
    let classTyped = classBuffer.bindMemory(to: UInt8.self, capacity: MemoryLayout<UInt8>.stride * classifications.count)
    
    let classBufferPointer = UnsafeBufferPointer(start: classTyped, count: classifications.count)
    return Array(classBufferPointer)
  }
  
  private func getIndexArray(meshAnchor: MeshAnchor) -> [UInt32]? {
    let indexBufferRawPointer = meshAnchor.geometry.faces.buffer.contents()
    
    let numIndices = meshAnchor.geometry.faces.count * 3
    
    let typedPointer = indexBufferRawPointer.bindMemory(to: UInt32.self, capacity: meshAnchor.geometry.faces.bytesPerIndex * numIndices)
    
    let indexBufferPointer = UnsafeBufferPointer(start: typedPointer, count: numIndices)
    return Array(indexBufferPointer)
  }
  
  private func readFloat3FromMTL(source: GeometrySource) -> [SIMD3<Float>] {
    var result:[SIMD3<Float>] = []
    
    let pointer = source.buffer.contents()
    for i in 0 ..< source.count {
      let dataPointer = pointer + source.offset + i * source.stride
      
      let pointer = dataPointer.bindMemory(to: SIMD3<Float>.self, capacity: MemoryLayout<SIMD3<Float>>.stride)
      result.append(pointer.pointee)
    }
    
    return result
  }
  
  private func getMeshResourceFromAnchor(meshAnchor: MeshAnchor, classes: [UInt8]? = nil) -> MeshResource? {
    guard meshAnchor.geometry.faces.primitive == .triangle,
          meshAnchor.geometry.vertices.format == .float3,
          let indexArray = getIndexArray(meshAnchor: meshAnchor) else {
            return nil
          }
    
    var contents = MeshResource.Contents()
    var part = MeshResource.Part(id: "part", materialIndex: 0)
    
    let positions = readFloat3FromMTL(source: meshAnchor.geometry.vertices)
    
    var resultIndexArray:[UInt32] = indexArray
    
    if let classes = classes {
      resultIndexArray = []
      for faceId in 0 ..< meshAnchor.geometry.faces.count {
        let classId = classes[faceId]
        //floor
        if classId == 2 {
          let v0:UInt32 = indexArray[faceId * 3]
          let v1:UInt32 = indexArray[faceId * 3 + 1]
          let v2:UInt32 = indexArray[faceId * 3 + 2]
          
          resultIndexArray.append(v0)
          resultIndexArray.append(v1)
          resultIndexArray.append(v2)
        }
      }
    }
    
    part.triangleIndices = MeshBuffer(resultIndexArray)
    part.positions = MeshBuffer(positions)
    
    let model = MeshResource.Model(id: "main", parts: [part])
    contents.models = [model]
    
    contents.instances = [.init(id: "instance", model: "main")]
    if let meshResource = try? MeshResource.generate(from: contents) {
      return meshResource
    }
    return nil
  }
  
  public func updateFrame(_ event: SceneEvents.Update) {
    if worldTracking.state == .running {
      if let headPosition = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
         let headContainer = controllerRoot.findEntity(named: "headContainer") {
        headContainer.transform = Transform(matrix: headPosition.originFromAnchorTransform)
      }
    }
    
    if handTracking.state == .running,
       let rightHand = handTracking.latestAnchors.rightHand,
       rightHand.isTracked,
       let scene = controllerRoot.scene,
       let part2Connector = part2Connector
    {
      let trm = Transform(matrix: rightHand.originFromAnchorTransform)
      
      let vacuumDirPoint: SIMD4<Float> = .init(x: -1.0, y: 0.0, z: 0.0, w: 1.0)
      
      let globalDirPoint = trm.matrix * vacuumDirPoint
      let globalDirPoint3:SIMD3<Float> = .init(x: globalDirPoint.x, y: globalDirPoint.y, z: globalDirPoint.z)
      
      part1Model?.position = trm.translation
      part1Model?.look(at: globalDirPoint3, from: trm.translation, relativeTo: controllerRoot)
      
      let globalPosConnector = part2Connector.position(relativeTo: controllerRoot)
      
      part2Model?.position = globalPosConnector
      let dir = globalDirPoint3 - trm.translation
      part2Model?.orientation = .init(angle: atan2(dir.x, dir.z), axis: .init(x: 0.0, y: 1.0, z: 0.0))
      
      let results = scene.raycast(from: trm.translation, to: globalPosConnector, mask: .sceneUnderstanding)
      if results.count > 0 {
        let offsetPosition = results[0].position - globalPosConnector
        part2Model?.position += offsetPosition
        part1Model?.position += offsetPosition
        
        if !isVacuumOn {
          isVacuumOn = true
          vacuumSoundController?.fade(to: -10.0, duration: 0.5)
          vacuumSoundController?.play()
        }
      } else if isVacuumOn {
        isVacuumOn = false
        vacuumSoundController?.fade(to: -100.0, duration: 0.5)
      }
    }
    
    if let part2Model = part2Model,
       let headContainer = controllerRoot.findEntity(named: "headContainer") {
      scoreEntity?.look(at: part2Model.position, from: headContainer.position, relativeTo: controllerRoot)
      scoreEntity?.position = part2Model.position + .init(x: 0.0, y: 0.3, z: 0.0)
    }
    
    updateCoins()
  }
  
  private func getVisualiseBox(name:String, color: UIColor, size:Float, parent:Entity? = nil) -> Entity {
    if let any = controllerRoot.findEntity(named: name) {
      return any
    }
    
    let vis = Entity.createEntityBox(color, size: size)
    vis.name = name
    if let parent = parent {
      parent.addChild(vis)
    } else {
      controllerRoot.addChild(vis)
    }
    
    return vis
  }
  
  public func updateView(_ content : inout RealityViewContent, attachments: RealityViewAttachments) {
    print("ssc::updateview")
    scoreEntity = attachments.entity(for: "score")
  }
  
  public func onTapSpatial(_ targetValue: EntityTargetValue<SpatialTapGesture.Value>) {
  }
  
  private var frameCounter:Int = 0
  
  private func updateCoins() {
    frameCounter += 1
    if frameCounter < 20 { return }
    frameCounter = 0
    
    for (key, value) in coins {
      addCoin(key: key, position: value)
    }
  }
  
  private func addCoin(key: String, position: SIMD3<Float>) {
    guard coinEntities[key] == nil,
          let coin = coinModel?.clone(recursive: true) else {
      return
    }
    
    coin.orientation = .init(angle: .random(in: 0 ... 1), axis: .init(x: 0.0, y: 1.0, z: 0.0))
    coin.position = position
    controllerRoot.addChild(coin)
    coinEntities[key] = coin
  }
  
  func setupSceneFirstTime() async {
    
    if let scene = try? await Entity(named: "VacuumAssets", in: realityKitContentBundle) {
      if let coin = scene.findEntity(named: "coin") {
        coin.components.set(RotateComponent())
        coin.components[CollisionComponent.self]?.filter.mask = vacuumCollisionGroup
        coin.components[CollisionComponent.self]?.filter.group = coinCollisionGroup
        coinModel = coin
      }
      
      if let part1 = scene.findEntity(named: "part1") {
        part1.components[CollisionComponent.self]?.filter.mask = coinCollisionGroup
        part1.components[CollisionComponent.self]?.filter.group = vacuumCollisionGroup
        part1Model = part1
        controllerRoot.addChild(part1)
        
        if let connector = part1.findEntity(named: "part2_connector") {
          part2Connector = connector
        }
      }
      
      if let part2 = scene.findEntity(named: "part2") {
        part2.components[CollisionComponent.self]?.filter.mask = coinCollisionGroup
        part2.components[CollisionComponent.self]?.filter.group = vacuumCollisionGroup
        part2Model = part2
        controllerRoot.addChild(part2)
      }
    }
  
    coinSound = try? await AudioFileResource(named: "/Root/collect_sound_wav", from: "VacuumAssets.usda", in: realityKitContentBundle)
    if let vacuumSound = try? await AudioFileResource(named: "/Root/vacuum_sound_wav", from: "VacuumAssets.usda", in: realityKitContentBundle) {
      vacuumSoundController = controllerRoot.prepareAudio(vacuumSound)
      vacuumSoundController?.gain = -20
      vacuumSoundController?.play()
    }
  }
  
  func updateAfterInject() {
  }
}

extension Entity {
  static func createEntityBox(_ color: UIColor, size: Float) -> Entity {
    let box = Entity()
    let modelComponent = ModelComponent(mesh: .generateBox(size: 0.2), materials: [UnlitMaterial(color: color)])
    box.components.set(modelComponent)
    return box
  }
}
