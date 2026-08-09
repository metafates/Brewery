//
//  Item.swift
//  Brewery
//
//  Created by vzbarashchenko on 09.08.2026.
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
