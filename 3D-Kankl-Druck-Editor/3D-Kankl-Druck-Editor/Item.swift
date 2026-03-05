//
//  Item.swift
//  3D-Kankl-Druck-Editor
//
//  Created by Andreas Pelczer on 05.03.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
