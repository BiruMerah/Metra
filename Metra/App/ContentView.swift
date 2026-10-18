//
//  ContentView.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import SwiftUI

struct ContentView: View {
    @State private var coordinator: AppCoordinator
    
    init(coordinator: AppCoordinator) {
        _coordinator = State(wrappedValue: coordinator)
    }
    
    var body: some View {
        NavigationStack(path: $coordinator.path) {
            coordinator.buildHome()
                .navigationDestination(for: AppRoutes.self) { route in
                    coordinator.buildView(route: route)
                }
        }
    }
}
