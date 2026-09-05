import Combine
import CoreLocation
import Foundation

struct IvyNavigationSummary: Equatable {
    var instruction: String
    var modifier: String?
    var maneuverDistanceMeters: Double
    var remainingDistanceMeters: Double
    var remainingDurationSeconds: Double
    var destinationName: String
}

struct IvySearchResult: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    static func == (lhs: IvySearchResult, rhs: IvySearchResult) -> Bool {
        lhs.name == rhs.name && lhs.subtitle == rhs.subtitle && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

final class MapNavigationProvider: ObservableObject {
    @Published private(set) var summary: IvyNavigationSummary?
    @Published private(set) var status = "NAV • GRAPHHOPPER READY"
    @Published private(set) var searchResults: [IvySearchResult] = []
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var destinationName: String?
    @Published private(set) var currentLocation: CLLocation?

    private var latestLocation: CLLocation?
    private var routeTask: URLSessionDataTask?
    private var searchTask: URLSessionDataTask?
    private var lastRerouteAt: TimeInterval = 0
    private var usingGraphHopperRoute = false
    private var graphHopperPoints: [CLLocationCoordinate2D] = []
    private var graphHopperInstructions: [GraphHopperRouteResponse.Path.Instruction] = []
    private var graphHopperRouteDistance: Double = 0
    private var graphHopperRouteTime: Double = 0
    private let minimumRerouteInterval: TimeInterval = 15
    private let offRouteDistanceMeters: CLLocationDistance = 80
    private let userAgent = "IvyADAS/1.0 (iOS; personal navigation project)"

    private var graphHopperAPIKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GraphHopperAPIKey") as? String, !key.isEmpty, !key.hasPrefix("__") else { return nil }
        return key
    }
    var isNavigating: Bool { destinationCoordinate != nil }

    func ingest(location: CLLocation) {
        latestLocation = location
        currentLocation = location
        guard destinationCoordinate != nil else { return }
        if usingGraphHopperRoute, !graphHopperPoints.isEmpty { updateGraphHopperProgress(location: location); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRerouteAt >= minimumRerouteInterval else { return }
        lastRerouteAt = now
        requestRoute()
    }

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { searchTask?.cancel(); searchResults = []; status = "NAV • READY"; return }
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [URLQueryItem(name:"q",value:trimmed),URLQueryItem(name:"format",value:"jsonv2"),URLQueryItem(name:"addressdetails",value:"1"),URLQueryItem(name:"limit",value:"6"),URLQueryItem(name:"countrycodes",value:"vn"),URLQueryItem(name:"accept-language",value:"vi")]
        guard let url = components?.url else { return }
        searchTask?.cancel(); status = "NAV • SEARCHING OSM"
        var request = URLRequest(url:url); request.setValue(userAgent,forHTTPHeaderField:"User-Agent"); request.setValue("vi",forHTTPHeaderField:"Accept-Language")
        searchTask = URLSession.shared.dataTask(with: request) { [weak self] data,response,error in
            guard let self else { return }
            guard error == nil, let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),let data else { DispatchQueue.main.async{self.status="NAV • SEARCH ERROR"}; return }
            do {
                let decoded=try JSONDecoder().decode([NominatimResult].self,from:data)
                let results=decoded.compactMap { item -> IvySearchResult? in guard let lat=Double(item.lat),let lon=Double(item.lon) else{return nil}; let title=item.name?.isEmpty == false ? item.name! : item.display_name.components(separatedBy:",").first ?? "Điểm đến"; return IvySearchResult(name:title,subtitle:item.display_name,coordinate:.init(latitude:lat,longitude:lon)) }
                DispatchQueue.main.async { self.searchResults=results; self.status=results.isEmpty ? "NAV • NO RESULT":"NAV • OSM RESULTS" }
            } catch { DispatchQueue.main.async{self.status="NAV • SEARCH PARSE ERROR"} }
        }; searchTask?.resume()
    }

    func startNavigation(to result:IvySearchResult){startNavigation(coordinate:result.coordinate,name:result.name)}
    func startNavigation(coordinate:CLLocationCoordinate2D,name:String){destinationCoordinate=coordinate;destinationName=name;searchResults=[];clearCachedRoute();lastRerouteAt=ProcessInfo.processInfo.systemUptime;requestRoute()}

    func importExternalShare(url:URL){
        let sharedURL:URL
        if url.scheme?.lowercased()=="ivy",let components=URLComponents(url:url,resolvingAgainstBaseURL:false),let raw=components.queryItems?.first(where:{$0.name=="url"})?.value,let decoded=URL(string:raw){sharedURL=decoded}else{sharedURL=url}
        status="NAV • READING SHARED PLACE"
        if let imported=extractDestination(from:sharedURL){startNavigation(coordinate:imported.coordinate,name:imported.name);return}
        guard sharedURL.scheme=="http" || sharedURL.scheme=="https" else{status="NAV • SHARE NOT SUPPORTED";return}
        var request=URLRequest(url:sharedURL);request.setValue(userAgent,forHTTPHeaderField:"User-Agent")
        URLSession.shared.dataTask(with:request){[weak self] _,response,error in guard let self else{return};guard error==nil,let resolvedURL=response?.url else{DispatchQueue.main.async{self.status="NAV • SHARE ERROR"};return};DispatchQueue.main.async{if let imported=self.extractDestination(from:resolvedURL){self.startNavigation(coordinate:imported.coordinate,name:imported.name)}else{self.status="NAV • PLACE NOT FOUND"}}}.resume()
    }

    func stopNavigation(){routeTask?.cancel();destinationCoordinate=nil;destinationName=nil;summary=nil;clearCachedRoute();status="NAV • GRAPHHOPPER READY"}

    private func requestRoute(){
        guard let origin=latestLocation?.coordinate,let destination=destinationCoordinate else{status="NAV • WAITING GPS";return}
        if let key=graphHopperAPIKey{requestGraphHopperRoute(origin:origin,destination:destination,key:key)}else{status="NAV • GRAPHHOPPER KEY MISSING";requestValhallaRoute(origin:origin,destination:destination)}
    }
    private func requestGraphHopperRoute(origin:CLLocationCoordinate2D,destination:CLLocationCoordinate2D,key:String){
        var c=URLComponents(string:"https://graphhopper.com/api/1/route")!;c.queryItems=[URLQueryItem(name:"point",value:"\(origin.latitude),\(origin.longitude)"),URLQueryItem(name:"point",value:"\(destination.latitude),\(destination.longitude)"),URLQueryItem(name:"profile",value:"car"),URLQueryItem(name:"locale",value:"vi"),URLQueryItem(name:"instructions",value:"true"),URLQueryItem(name:"calc_points",value:"true"),URLQueryItem(name:"points_encoded",value:"false"),URLQueryItem(name:"key",value:key)];guard let url=c.url else{return};routeTask?.cancel();status="NAV • GRAPHHOPPER ROUTING";var request=URLRequest(url:url);request.setValue(userAgent,forHTTPHeaderField:"User-Agent");routeTask=URLSession.shared.dataTask(with:request){[weak self] data,response,error in guard let self else{return};guard error==nil,let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),let data else{DispatchQueue.main.async{self.status="NAV • GRAPHHOPPER ERROR";self.requestValhallaRoute(origin:origin,destination:destination)};return};do{let decoded=try JSONDecoder().decode(GraphHopperRouteResponse.self,from:data);guard let path=decoded.paths.first,!path.points.coordinates.isEmpty else{throw URLError(.cannotParseResponse)};let points=path.points.coordinates.map{CLLocationCoordinate2D(latitude:$0[1],longitude:$0[0])};DispatchQueue.main.async{self.usingGraphHopperRoute=true;self.graphHopperPoints=points;self.graphHopperInstructions=path.instructions;self.graphHopperRouteDistance=path.distance;self.graphHopperRouteTime=Double(path.time)/1000;self.status="NAV • GRAPHHOPPER ACTIVE";if let location=self.latestLocation{self.updateGraphHopperProgress(location:location)}}}catch{DispatchQueue.main.async{self.status="NAV • GRAPHHOPPER PARSE ERROR";self.requestValhallaRoute(origin:origin,destination:destination)}}};routeTask?.resume()
    }
    private func updateGraphHopperProgress(location:CLLocation){
        guard !graphHopperPoints.isEmpty else{return};let nearest=graphHopperPoints.enumerated().min{location.distance(from:CLLocation(latitude:$0.element.latitude,longitude:$0.element.longitude)) < location.distance(from:CLLocation(latitude:$1.element.latitude,longitude:$1.element.longitude))};guard let nearest else{return};let off=location.distance(from:CLLocation(latitude:nearest.element.latitude,longitude:nearest.element.longitude));if off>offRouteDistanceMeters{let now=ProcessInfo.processInfo.systemUptime;if now-lastRerouteAt>=minimumRerouteInterval{lastRerouteAt=now;requestRoute()};return};let idx=nearest.offset;let instruction=graphHopperInstructions.first{$0.interval.count>=2 && idx <= $0.interval[1] && idx >= $0.interval[0]} ?? graphHopperInstructions.last;guard let instruction else{return};let remainingRoute=polylineDistance(Array(graphHopperPoints[idx...]));let fraction=graphHopperRouteDistance>0 ? min(max(remainingRoute/graphHopperRouteDistance,0),1):0;let maneuverIndex=min(max(instruction.interval.last ?? idx,idx),graphHopperPoints.count-1);let maneuverDistance=polylineDistance(Array(graphHopperPoints[idx...maneuverIndex]));summary=IvyNavigationSummary(instruction:instruction.text,modifier:modifier(for:instruction.sign),maneuverDistanceMeters:maneuverDistance,remainingDistanceMeters:remainingRoute,remainingDurationSeconds:graphHopperRouteTime*fraction,destinationName:destinationName ?? "Điểm đến")
    }
    private func requestValhallaRoute(origin:CLLocationCoordinate2D,destination:CLLocationCoordinate2D){
        let locations="[{\"lat\":\(origin.latitude),\"lon\":\(origin.longitude)},{\"lat\":\(destination.latitude),\"lon\":\(destination.longitude)}]";var c=URLComponents(string:"https://valhalla1.openstreetmap.de/route")!;c.queryItems=[URLQueryItem(name:"json",value:"{\"locations\":\(locations),\"costing\":\"auto\",\"units\":\"kilometers\",\"language\":\"vi-VN\"}")];guard let url=c.url else{return};status="NAV • OSM FALLBACK";var req=URLRequest(url:url);req.setValue(userAgent,forHTTPHeaderField:"User-Agent");routeTask=URLSession.shared.dataTask(with:req){[weak self] data,response,error in guard let self else{return};guard error==nil,let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),let data else{DispatchQueue.main.async{self.status="NAV • ROUTE ERROR"};return};do{let decoded=try JSONDecoder().decode(ValhallaRouteResponse.self,from:data);guard let leg=decoded.trip.legs.first,let maneuver=leg.maneuvers.first else{return};DispatchQueue.main.async{self.usingGraphHopperRoute=false;self.summary=IvyNavigationSummary(instruction:maneuver.instruction,modifier:nil,maneuverDistanceMeters:maneuver.length*1000,remainingDistanceMeters:decoded.trip.summary.length*1000,remainingDurationSeconds:decoded.trip.summary.time,destinationName:self.destinationName ?? "Điểm đến");self.status="NAV • OSM FALLBACK ACTIVE"}}catch{DispatchQueue.main.async{self.status="NAV • ROUTE PARSE ERROR"}}};routeTask?.resume()
    }
    private func extractDestination(from url:URL)->(coordinate:CLLocationCoordinate2D,name:String)?{let s=url.absoluteString.removingPercentEncoding ?? url.absoluteString;let patterns=["@(-?[0-9]+(?:\\.[0-9]+)?),(-?[0-9]+(?:\\.[0-9]+)?)","!3d(-?[0-9]+(?:\\.[0-9]+)?)!4d(-?[0-9]+(?:\\.[0-9]+)?)"];for p in patterns{if let r=try? NSRegularExpression(pattern:p),let m=r.firstMatch(in:s,range:NSRange(s.startIndex...,in:s)),let a=Range(m.range(at:1),in:s),let b=Range(m.range(at:2),in:s),let lat=Double(s[a]),let lon=Double(s[b]){return(.init(latitude:lat,longitude:lon),"Điểm đã chia sẻ")}};if let c=URLComponents(url:url,resolvingAgainstBaseURL:false){for key in ["ll","q","query","destination"]{if let value=c.queryItems?.first(where:{$0.name==key})?.value{let parts=value.split(separator:",");if parts.count>=2,let lat=Double(parts[0].trimmingCharacters(in:.whitespaces)),let lon=Double(parts[1].trimmingCharacters(in:.whitespaces)){return(.init(latitude:lat,longitude:lon),"Điểm đã chia sẻ")}}}};return nil}
    private func clearCachedRoute(){usingGraphHopperRoute=false;graphHopperPoints=[];graphHopperInstructions=[];graphHopperRouteDistance=0;graphHopperRouteTime=0}
    private func polylineDistance(_ points:[CLLocationCoordinate2D])->Double{guard points.count>1 else{return 0};return zip(points,points.dropFirst()).reduce(0){$0+CLLocation(latitude:$1.0.latitude,longitude:$1.0.longitude).distance(from:CLLocation(latitude:$1.1.latitude,longitude:$1.1.longitude))}}
    private func modifier(for sign:Int)->String?{switch sign{case -3,-2:return "left";case 2,3:return "right";case -98:return "uturn";case 6:return "roundabout";default:return "straight"}}
}

private struct NominatimResult:Decodable{let lat:String;let lon:String;let display_name:String;let name:String?}
private struct GraphHopperRouteResponse:Decodable{struct Path:Decodable{struct Points:Decodable{let coordinates:[[Double]]};struct Instruction:Decodable{let text:String;let distance:Double;let time:Int;let sign:Int;let interval:[Int]};let distance:Double;let time:Int;let points:Points;let instructions:[Instruction]};let paths:[Path]}
private struct ValhallaRouteResponse:Decodable{struct Trip:Decodable{struct Summary:Decodable{let length:Double;let time:Double};struct Leg:Decodable{struct Maneuver:Decodable{let instruction:String;let length:Double};let maneuvers:[Maneuver]};let summary:Summary;let legs:[Leg]};let trip:Trip}
