import Foundation
import FoundationModels
struct TranscriptSegment:Sendable { var start:Double;var end:Double;var text:String;var source:AudioSource;var speaker:String?=nil;var kind:TranscriptKind?=nil;var includeInMeetingNotes:Bool {kind != .agentCommand};var displaySpeaker:String{speaker ?? (source == .mic ? "You":"Others")}}
enum AudioSource:Sendable{case mic,system};enum TranscriptKind:Sendable{case speech,agentCommand}
struct Meeting:Sendable{var id=UUID();var title:String;var start:Date;var end:Date?=nil;var status:Status;var speakerNames:[String:String]=[:];var attendees:[String]=[];var duration:Double?{end?.timeIntervalSince(start)}}
enum Status:Sendable{case summarizing}
extension Double {var counterText:String{String(format:"%02d:%02d",Int(self)/60,Int(self)%60)}}
extension Array where Element == TranscriptSegment {func plainText(speakerNames:[String:String]=[:])->String{filter(\.includeInMeetingNotes).map{"[\($0.start.counterText)] \(speakerNames[$0.displaySpeaker] ?? $0.displaySpeaker): \($0.text)"}.joined(separator:"\n")}}
struct MeetingNotesBrief:Sendable{var memory:String;var decisions:String;static let empty=Self(memory:"",decisions:"");var promptBlock:String{isEmpty ? "":"Known context\n"+memory+decisions};var isEmpty:Bool{memory.isEmpty&&decisions.isEmpty}}
enum ModelRole:Sendable{case meetingNotes};enum UsageFallback:Sendable{};enum UsageFeature:Sendable{case meetingNotesSingle,meetingNotesMap,meetingNotesReduce,meetingNotesCollapse}
struct UsageCorrelation:Sendable{let meetingID:UUID};enum LlamaError:Error{case inputTooLong}
enum LLMProviderID:Sendable{case appLLM,appleFoundation,localServer}
struct LLMCompletion:Sendable{let text:String;let generatedTokens:Int;let duration:Double;var finishedByLimit=false}
protocol LLMProvider:Sendable{var id:LLMProviderID{get};var contextTokens:Int{get};var displayModelName:String{get};var unavailableReason:String?{get async};func countTokens(_ text:String)async throws->Int;func complete(system:String,user:String,maxTokens:Int)async throws->LLMCompletion;func complete(system:String,user:String,maxTokens:Int,grammar:GBNFGrammar)async throws->LLMCompletion}
extension LLMProvider{var displayModelName:String{"stub"};func complete(system:String,user:String,maxTokens:Int,grammar:GBNFGrammar)async throws->LLMCompletion{try await complete(system:system,user:user,maxTokens:maxTokens)}}
final class ModelPassRecorder:Sendable{@TaskLocal static var current:ModelPassRecorder?;init(feature:UsageFeature,pass:String,provider:any LLMProvider,ids:UsageCorrelation,requestedRole:ModelRole?){};func fellBack(_ f:UsageFallback){};func noteCounts(_ c:[String:Int]){};func report(promptTokens:Int?,cachedTokens:Int?,completionTokens:Int?,reasoningTokens:Int?,finishReason:String?,estimated:Bool){};func finish(reason:String){};func fail(_ e:Error){}}
enum FoundationModelFormatter{static var unavailableReason:String?{"Standalone harness intentionally skips native model"}}
struct FoundationModelLLMProvider:LLMProvider{let id=LLMProviderID.appleFoundation;let contextTokens=4096;var unavailableReason:String?{get async{nil}};func countTokens(_ text:String)async throws->Int{text.count/4};func complete(system:String,user:String,maxTokens:Int)async throws->LLMCompletion{fatalError()}}
