import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ServerAiPage extends StatefulWidget {
  final String backendUrl;
  final String apiToken;
  final Map<String,dynamic>? initialSnapshot;
  final String symbol;
  const ServerAiPage({super.key,required this.backendUrl,required this.apiToken,this.initialSnapshot,this.symbol='NIFTY'});
  @override State<ServerAiPage> createState()=>_ServerAiPageState();
}

class _ServerAiPageState extends State<ServerAiPage>{
  bool busy=false;
  Map<String,dynamic> result=<String,dynamic>{};
  Map<String,dynamic> snapshot=<String,dynamic>{};
  String status='Ready • server-side six-AI';
  String get base=>widget.backendUrl.replaceFirst(RegExp(r'/+$'),'');
  String get symbol=>widget.symbol.toUpperCase();

  @override void initState(){super.initState();snapshot=widget.initialSnapshot??{};run();}
  Future<void> run() async {
    if(busy || base.isEmpty)return;
    setState(()=>busy=true);
    try{
      final headers=<String,String>{if(widget.apiToken.isNotEmpty)'x-token':widget.apiToken};
      final c=await http.get(Uri.parse(base+'/v1/ai/context?index='+Uri.encodeQueryComponent(symbol)),headers:headers).timeout(const Duration(seconds:18));
      if(c.statusCode==200){
        final d=jsonDecode(c.body);
        if(d is Map<String,dynamic>)snapshot=d;
      }
      final postHeaders=<String,String>{'Content-Type':'application/json',if(widget.apiToken.isNotEmpty)'x-token':widget.apiToken};
      final r=await http.post(Uri.parse(base+'/v1/ai/validate'),headers:postHeaders,body:jsonEncode(<String,dynamic>{'payload':snapshot})).timeout(const Duration(seconds:45));
      final d=jsonDecode(r.body);
      if(r.statusCode!=200 || d is! Map<String,dynamic>)throw Exception('HTTP '+r.statusCode.toString());
      if(mounted)setState(()=>result=d);
      if(mounted)setState(()=>status='Live six-AI result • '+DateTime.now().toLocal().toString().substring(11,19));
    }catch(e){if(mounted)setState(()=>status='AI connection error: '+e.toString());}
    finally{if(mounted)setState(()=>busy=false);}
  }

  @override Widget build(BuildContext context){
    final rows=result['providers'] is List?List<dynamic>.from(result['providers']):<dynamic>[];
    final finalState=(result['final']??'WAIT').toString();
    final success=(result['successful']??0).toString();
    return ListView(padding:const EdgeInsets.all(12),children:<Widget>[
      Card(child:Padding(padding:const EdgeInsets.all(15),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
        const Text('6-AI • LIVE SERVER VALIDATION',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
        const SizedBox(height:5),
        Text('Luna • Claude • Sol • DeepSeek • Gemini • Grok',style:TextStyle(color:Colors.grey[400])),
        const SizedBox(height:10),
        Text(status,style:TextStyle(color:busy?Colors.orange:Colors.green,fontWeight:FontWeight.bold)),
        const SizedBox(height:8),
        FilledButton.icon(onPressed:busy?null:run,icon:const Icon(Icons.refresh),label:const Text('RUN LIVE 6-AI')),
      ]))),
      Card(child:ListTile(
        title:Text('FINAL: '+finalState,style:const TextStyle(fontWeight:FontWeight.bold)),
        subtitle:Text((result['reason']??'Waiting for server validation.').toString()),
        trailing:Chip(label:Text(success+'/'+(result['total']??6).toString())),
      )),
      ...rows.map((x){
        final m=x is Map?Map<String,dynamic>.from(x):<String,dynamic>{};
        final t=(m['text']??m['error']??'No response').toString();
        final match=RegExp(r'(?im)^\s*STATE\s*:\s*(CALL BUY|PUT BUY|WAIT|NO QUALIFYING TRADE)').firstMatch(t);
        final state=match?.group(1)??'WAIT';
        return Card(child:ExpansionTile(
          title:Text((m['name']??'AI Provider').toString()),
          subtitle:Text((m['model']??'').toString()+' • '+(m['status']??'').toString()),
          leading:const Icon(Icons.psychology),
          children:<Widget>[Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
            Chip(label:Text(state)),
            const SizedBox(height:6),
            Text(t),
          ]))],
        ));
      }),
      const Padding(padding:EdgeInsets.all(8),child:Text('Provider keys remain server-side; APK receives validation results only.',style:TextStyle(color:Colors.grey))),
    ]);
  }
}
