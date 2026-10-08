//
//  Item.swift
//  MacCast
//
//  Created by Damian Derlecki on 13/09/2026.
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
