import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 64))
                Text("LowPolyCam")
                    .font(.largeTitle.bold())
                Text("Ready to build.")
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.white)
        }
    }
}

