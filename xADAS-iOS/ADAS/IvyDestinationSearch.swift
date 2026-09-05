import AVFoundation
import Combine
import CoreLocation
import MapKit
import Speech

struct IvyAddressSuggestion: Identifiable { let id=UUID(); let title:String; let subtitle:String; fileprivate let completion:MKLocalSearchCompletion }

@MainActor
final class IvyDestinationSearch:NSObject,ObservableObject,MKLocalSearchCompleterDelegate {
    @Published var suggestions:[IvyAddressSuggestion]=[]
    @Published var isListening=false
    @Published var speechError:String?
    private let completer=MKLocalSearchCompleter(); private let recognizer=SFSpeechRecognizer(locale:Locale(identifier:"vi-VN")); private let audioEngine=AVAudioEngine()
    private var speechRequest:SFSpeechAudioBufferRecognitionRequest?; private var speechTask:SFSpeechRecognitionTask?; private var tapInstalled=false; private var ownsRecordingSession=false
    override init(){super.init();completer.delegate=self;completer.resultTypes=[.address,.pointOfInterest]}
    func update(query:String,near location:CLLocation?){let text=query.trimmingCharacters(in:.whitespacesAndNewlines);guard text.count>=2 else{suggestions=[];completer.queryFragment="";return};if let location{completer.region=MKCoordinateRegion(center:location.coordinate,latitudinalMeters:80_000,longitudinalMeters:80_000)};completer.queryFragment=text}
    func completerDidUpdateResults(_ completer:MKLocalSearchCompleter){suggestions=Array(completer.results.prefix(8)).map{IvyAddressSuggestion(title:$0.title,subtitle:$0.subtitle,completion:$0)}}
    func completer(_ completer:MKLocalSearchCompleter,didFailWithError error:Error){suggestions=[]}
    func resolve(_ suggestion:IvyAddressSuggestion,completion:@escaping(IvySearchResult?)->Void){let request=MKLocalSearch.Request(completion:suggestion.completion);request.resultTypes=[.address,.pointOfInterest];MKLocalSearch(request:request).start{response,_ in guard let item=response?.mapItems.first else{completion(nil);return};let name=item.name ?? suggestion.title;let subtitle=[item.placemark.subThoroughfare,item.placemark.thoroughfare,item.placemark.locality,item.placemark.administrativeArea].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:", ");completion(IvySearchResult(name:name,subtitle:subtitle.isEmpty ? suggestion.subtitle:subtitle,coordinate:item.placemark.coordinate))}}
    func toggleVoice(onText:@escaping(String)->Void){if isListening{stopVoice();return};speechError=nil;SFSpeechRecognizer.requestAuthorization{[weak self] status in DispatchQueue.main.async{guard status == .authorized else{self?.speechError=status == .denied ? "Quyền nhận dạng giọng nói đang bị tắt":"Chưa cấp quyền nhận dạng giọng nói";return};self?.requestMicrophoneAndStart(onText:onText)}}}
    private func requestMicrophoneAndStart(onText:@escaping(String)->Void){AVAudioSession.sharedInstance().requestRecordPermission{[weak self] granted in DispatchQueue.main.async{guard granted else{self?.speechError="Quyền micro đang bị tắt";return};self?.startVoice(onText:onText)}}}
    private func startVoice(onText:@escaping(String)->Void){stopVoice();guard let recognizer,recognizer.isAvailable else{speechError="Nhận dạng giọng nói chưa sẵn sàng";return};do{try IvyAudioSessionManager.shared.beginRecording();ownsRecordingSession=true;let request=SFSpeechAudioBufferRecognitionRequest();request.shouldReportPartialResults=true;speechRequest=request;let input=audioEngine.inputNode;let format=input.outputFormat(forBus:0);guard format.sampleRate>0,format.channelCount>0 else{speechError="Micro chưa sẵn sàng";stopVoice();return};input.installTap(onBus:0,bufferSize:1024,format:format){buffer,_ in request.append(buffer)};tapInstalled=true;audioEngine.prepare();try audioEngine.start();isListening=true;speechTask=recognizer.recognitionTask(with:request){[weak self] result,error in DispatchQueue.main.async{if let raw=result?.bestTranscription.formattedString,!raw.isEmpty{onText(Self.normalizeSpokenAddress(raw))};if result?.isFinal == true || error != nil{self?.stopVoice()}}}}catch{speechError="Không thể bật micro";stopVoice()}}

    private static func normalizeSpokenAddress(_ text:String)->String {
        let words=text.split(separator:" ").map(String.init);guard !words.isEmpty,!words[0].contains(where:{$0.isNumber}) else{return text}
        let d:[String:Int]=["không":0,"một":1,"mốt":1,"hai":2,"ba":3,"bốn":4,"tư":4,"năm":5,"lăm":5,"sáu":6,"bảy":7,"tám":8,"chín":9]
        var total=0,group=0,i=0,consumed=0,saw=false
        while i<words.count { let w=words[i].lowercased();if w=="linh" || w=="lẻ"{consumed=i+1;i+=1;continue};guard let n=d[w] else{break};saw=true;let next=i+1<words.count ? words[i+1].lowercased():"";if next=="trăm"{group += n*100;i+=2;consumed=i;continue};if next=="mươi"{group += n*10;i+=2;consumed=i;continue};group += n;i+=1;consumed=i;if i<words.count{let unit=words[i].lowercased();if unit=="nghìn" || unit=="ngàn"{total += group*1000;group=0;i+=1;consumed=i}} }
        guard saw,consumed>0,total+group>0 else{return text};return ([String(total+group)]+Array(words.dropFirst(consumed))).joined(separator:" ")
    }
    func stopVoice(){if audioEngine.isRunning{audioEngine.stop()};if tapInstalled{audioEngine.inputNode.removeTap(onBus:0);tapInstalled=false};speechRequest?.endAudio();speechTask?.cancel();speechRequest=nil;speechTask=nil;isListening=false;if ownsRecordingSession{ownsRecordingSession=false;IvyAudioSessionManager.shared.endRecording()}}
}
