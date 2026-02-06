import SwiftUI
import MapKit

struct PositionMapSheet: View {
    let coordinate: CLLocationCoordinate2D
    let title: String
    @AppStorage("mapProvider") private var mapProviderRaw = MapProvider.appleMaps.rawValue
    @Environment(\.dismiss) private var dismiss

    private var mapProvider: MapProvider {
        MapProvider(rawValue: mapProviderRaw) ?? .appleMaps
    }

    var body: some View {
        NavigationStack {
            PositionMapView(
                coordinate: coordinate,
                title: title,
                mapProvider: mapProvider
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Schließen") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openInExternalMaps()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    private func openInExternalMaps() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = title
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        ])
    }
}

#Preview {
    PositionMapSheet(
        coordinate: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
        title: "Max Mustermann"
    )
}
