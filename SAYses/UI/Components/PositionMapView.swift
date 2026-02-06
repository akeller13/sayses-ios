import SwiftUI
import MapKit

struct PositionMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let title: String
    let mapProvider: MapProvider

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator

        // Add annotation
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = title
        mapView.addAnnotation(annotation)

        // Center on coordinate with ~500m zoom
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        )
        mapView.setRegion(region, animated: false)

        // Apply tile overlay for OSM
        applyTileOverlay(to: mapView)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update tile overlay if provider changed
        mapView.removeOverlays(mapView.overlays)
        applyTileOverlay(to: mapView)
    }

    private func applyTileOverlay(to mapView: MKMapView) {
        switch mapProvider {
        case .appleMaps:
            // Standard Apple Maps, no overlay needed
            mapView.mapType = .standard
        case .openStreetMap:
            let template = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
            let overlay = MKTileOverlay(urlTemplate: template)
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
            // OSM supports max zoom 19 — limit camera to prevent empty tiles
            // OSM tiles exist up to zoom 19 (~300m camera distance). Prevent zooming further.
            mapView.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 300)
        }
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
