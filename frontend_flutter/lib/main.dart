import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path/path.dart' as path;

// Extension to capitalize strings
extension StringExtension on String {
  String capitalize() => isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}

void main() => runApp(const ChatbotApp());

class ChatbotApp extends StatelessWidget {
  const ChatbotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Chatbot',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.grey[900],
      ),
      themeMode: ThemeMode.system,
      home: const ChatbotHomePage(),
    );
  }
}

class ChatbotHomePage extends StatefulWidget {
  const ChatbotHomePage({super.key});

  @override
  _ChatbotHomePageState createState() => _ChatbotHomePageState();
}

class Message {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String? audioPath;
  final double? confidence;

  Message({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.audioPath,
    this.confidence,
  });
}

class _ChatbotHomePageState extends State<ChatbotHomePage> {
  // Constants
  static const _inputDecorations = _InputDecorations();
  static const _connectionColors = _ConnectionColors();
  
  // Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  // State variables
  final List<Message> _messages = [];
  String _voice = 'default';
  double _speed = 1.0;
  bool _isRecording = false;
  bool _isProcessing = false;
  bool _isConnected = true;
  bool _isTyping = false;
  String? _errorMessage;
  String? _audioPath;
  
  // Audio handling
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _recorder = AudioRecorder();
  
  // Cache and configuration
  final Map<String, String> _ttsCache = {};
  String _storagePath = 'D:\\tts_stt_app_files';
  String _serverIP = '127.0.0.1';
  int _serverPort = 5000;
  
  // API endpoints
  late String _serverBaseUrl;
  late String _ttsApiUrl;
  late String _sttApiUrl;
  late String _geminiApiUrl;
  late String _statusApiUrl;
  
  // Connection monitoring
  Timer? _connectionTimer;
  bool _connectionTestPerformed = false;
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _updateEndpoints();
    _initializeApp();
    
    // Add welcome message
    _messages.add(Message(
      text: "Hello! I am your voice assistant powered by Gemini. Ask me anything or speak using the microphone button.",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }
  
  void _updateEndpoints() {
    _serverBaseUrl = 'http://$_serverIP:$_serverPort';
    _ttsApiUrl = '$_serverBaseUrl/api/convert';
    _sttApiUrl = '$_serverBaseUrl/api/transcribe';
    _geminiApiUrl = '$_serverBaseUrl/api/gemini';
    _statusApiUrl = '$_serverBaseUrl/api/status';
  }

  Future<void> _initializeApp() async {
    await _setupStorage();
    await _checkConnectivity();
    
    // Set up periodic connectivity check
    _connectionTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkConnectivity();
    });
    
    // Listen for connectivity changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (result == ConnectivityResult.none) {
        setState(() => _isConnected = false);
      } else {
        _checkServerConnection();
      }
    });
    
    // Clean up old files on startup
    _cleanupOldFiles(silent: true);
  }

  Future<void> _setupStorage() async {
    try {
      // Try D drive first
      final dDriveDir = Directory(_storagePath);
      if (!await dDriveDir.exists()) {
        await dDriveDir.create(recursive: true);
      }
      if (await _isDirectoryWritable(_storagePath)) {
        debugPrint("Using D drive storage path: $_storagePath");
        return;
      }
      throw Exception('D drive storage path is not writable');
    } catch (e) {
      debugPrint("Error setting up D drive storage: $e");
      // Try app documents directory
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final appAudioDir = Directory(path.join(appDir.path, 'audio_files'));
        if (!await appAudioDir.exists()) {
          await appAudioDir.create(recursive: true);
        }
        _storagePath = appAudioDir.path;
        debugPrint("Fallback to app directory: $_storagePath");
        _errorMessage = 'Using app directory: $_storagePath';
      } catch (_) {
        // Last resort: use temp directory
        final tempDir = await getTemporaryDirectory();
        _storagePath = tempDir.path;
        debugPrint("Fallback to temp directory: $_storagePath");
        _errorMessage = 'Using temp directory: $_storagePath';
      }
      setState(() {});
    }
  }

  Future<bool> _isDirectoryWritable(String dirPath) async {
    try {
      final directory = Directory(dirPath);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final testFile = File(path.join(dirPath, 'write_test_${DateTime.now().millisecondsSinceEpoch}.tmp'));
      await testFile.writeAsString('Test write');
      await testFile.delete();
      return true;
    } catch (e) {
      debugPrint("Directory is not writable: $dirPath, Error: $e");
      return false;
    }
  }

  Future<void> _checkConnectivity() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    bool wasConnected = _isConnected;
    
    setState(() => _isConnected = connectivityResult != ConnectivityResult.none);
    
    if (_isConnected && (!wasConnected || !_connectionTestPerformed)) {
      await _checkServerConnection();
    }
  }

  Future<void> _checkServerConnection() async {
    if (_isProcessing) return;
    
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });
    
    try {
      final response = await http.get(Uri.parse(_statusApiUrl))
          .timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['status'] ?? 'unknown';
        final services = data['services'] ?? {};
        
        setState(() {
          _isConnected = status == 'healthy' && 
                         services['tts'] == 'ok' && 
                         services['stt'] == 'ok' && 
                         services['gemini'] == 'ok';
          _errorMessage = _isConnected ? null : 'Server services not fully operational';
          _connectionTestPerformed = true;
        });
      } else {
        throw Exception('Status check failed: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _isConnected = false;
        _errorMessage = 'Server connection failed: ${e.toString().split('\n')[0]}';
        _connectionTestPerformed = true;
      });
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _recorder.dispose();
    _connectionTimer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<String> _getGeminiResponse(String message) async {
    if (!_isConnected) {
      return 'No internet connection. Please check your network.';
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse(_geminiApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'prompt': message}),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['response'] ?? 'No response received.';
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception('Server error: ${errorData['error'] ?? response.statusCode}');
      }
    } on SocketException {
      return 'Connection error: Server might be offline.';
    } on TimeoutException {
      return 'Server request timed out.';
    } catch (e) {
      return 'Error: ${e.toString().split('\n')[0]}';
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    
    final userMessage = Message(
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
    );
    
    setState(() {
      _messages.add(userMessage);
      _messageController.clear();
      _isTyping = true;
    });
    
    _scrollToBottom();
    
    final response = await _getGeminiResponse(text);
    
    setState(() {
      _isTyping = false;
      _messages.add(Message(
        text: response,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
    
    _scrollToBottom();
    
    await _convertTextToSpeech(response);
  }

  Future<void> _convertTextToSpeech([String? textToConvert]) async {
    final text = textToConvert ?? _messages.last.text;
    if (!_isConnected) {
      setState(() => _errorMessage = 'No internet connection. Please check your network.');
      return;
    }

    // Check cache first
    final cacheKey = '$text-$_voice-$_speed';
    if (_ttsCache.containsKey(cacheKey)) {
      await _playAudioFile(_ttsCache[cacheKey]!);
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      await _audioPlayer.stop();
      
      final response = await http.post(
        Uri.parse(_ttsApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': text,
          'voice': _voice.toLowerCase(),
          'speed': _speed,
        }),
      ).timeout(const Duration(seconds: 30));
      
      if (response.statusCode == 200) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final audioFilePath = path.join(_storagePath, 'speech_$timestamp.wav');
        final audioFile = File(audioFilePath);
        final directory = Directory(path.dirname(audioFilePath));
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        
        await audioFile.writeAsBytes(response.bodyBytes);
        
        if (await audioFile.exists()) {
          _ttsCache[cacheKey] = audioFile.path;
          await _playAudioFile(audioFile.path);
          setState(() => _audioPath = audioFile.path);
        } else {
          throw Exception('Failed to save audio file');
        }
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception('TTS error: ${errorData['error'] ?? response.statusCode}');
      }
    } catch (e) {
      setState(() => _errorMessage = 'TTS error: ${e.toString().split('\n')[0]}');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _playAudioFile(String audioPath) async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(audioPath));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing audio: ${e.toString().split('\n')[0]}')),
      );
    }
  }

  Future<void> _startRecording() async {
    if (!_isConnected) {
      setState(() => _errorMessage = 'No internet connection. Please check your network.');
      return;
    }

    final status = await Permission.microphone.request();
    if (status.isGranted) {
      setState(() {
        _isRecording = true;
        _errorMessage = null;
      });

      try {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final audioFilePath = path.join(_storagePath, 'recording_$timestamp.wav');
        final directory = Directory(path.dirname(audioFilePath));
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        
        await _recorder.start(const RecordConfig(
          encoder: AudioEncoder.wav,
          bitRate: 128000,
          sampleRate: 44100,
        ), path: audioFilePath);
      } catch (e) {
        setState(() {
          _isRecording = false;
          _errorMessage = 'Recording failed: ${e.toString().split('\n')[0]}';
        });
      }
    } else {
      setState(() => _errorMessage = 'Microphone permission denied');
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    
    setState(() {
      _isRecording = false;
      _isProcessing = true;
    });

    try {
      final recordedPath = await _recorder.stop();
      
      if (recordedPath != null) {
        _audioPath = recordedPath;
        final audioFile = File(recordedPath);
        if (await audioFile.exists() && await audioFile.length() > 0) {
          await _transcribeAudio(audioFile);
        } else {
          setState(() {
            _errorMessage = 'Recording file not found or empty';
            _isProcessing = false;
          });
        }
      } else {
        setState(() {
          _errorMessage = 'No recording available';
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Recording error: ${e.toString().split('\n')[0]}';
        _isProcessing = false;
      });
    }
  }

  Future<void> _transcribeAudio(File audioFile) async {
    if (!_isConnected) {
      setState(() {
        _errorMessage = 'No internet connection. Please check your network.';
        _isProcessing = false;
      });
      return;
    }

    try {
      var request = http.MultipartRequest('POST', Uri.parse(_sttApiUrl));
      request.files.add(await http.MultipartFile.fromPath('audio', audioFile.path));
      
      final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        final transcript = result['transcript'] ?? '';
        final confidence = result['confidence'] ?? 0.0;
        
        if (transcript.isNotEmpty && transcript != 'No speech detected, please try again.') {
          setState(() {
            _messages.add(Message(
              text: confidence < 0.7 ? '$transcript (low confidence)' : transcript,
              isUser: true,
              timestamp: DateTime.now(),
              audioPath: audioFile.path,
              confidence: confidence,
            ));
            _isTyping = true;
          });
          _scrollToBottom();
          
          final geminiResponse = await _getGeminiResponse(transcript);
          
          setState(() {
            _isTyping = false;
            _messages.add(Message(
              text: geminiResponse,
              isUser: false,
              timestamp: DateTime.now(),
            ));
          });
          _scrollToBottom();
          await _convertTextToSpeech(geminiResponse);
        } else {
          setState(() => _errorMessage = transcript.isEmpty ? 
              'Could not transcribe audio. Please try again.' : transcript);
        }
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception('STT error: ${errorData['error'] ?? response.statusCode}');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Transcription error: ${e.toString().split('\n')[0]}');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _testServerConnection() async {
    await _checkServerConnection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_isConnected ? 'Server is online' : 'Server is offline: $_errorMessage')),
    );
  }

  Future<void> _cleanupOldFiles({bool silent = false}) async {
    try {
      final directory = Directory(_storagePath);
      if (await directory.exists()) {
        final files = directory.listSync();
        final now = DateTime.now();
        int deletedCount = 0;
        
        List<Future<void>> deletionFutures = [];
        
        for (var file in files) {
          if (file is File) {
            final stat = file.statSync();
            if (now.difference(stat.modified).inHours > 1) {
              deletionFutures.add(file.delete());
              deletedCount++;
            }
          }
        }
        
        await Future.wait(deletionFutures);
        
        if (!silent && deletedCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cleaned up $deletedCount old files')),
          );
        } else if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No old files to clean up')),
          );
        }
        
        if (_ttsCache.length > 50) {
          _ttsCache.clear();
        }
      }
    } catch (e) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error cleaning up files: ${e.toString().split('\n')[0]}')),
        );
      }
    }
  }

  // UI Dialog methods
  Future<void> _updateServerConfig() async {
    await showDialog(
      context: context,
      builder: (context) {
        final ipController = TextEditingController(text: _serverIP);
        final portController = TextEditingController(text: _serverPort.toString());
        return AlertDialog(
          title: const Text('Server Configuration'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: _inputDecorations.serverIp,
                controller: ipController,
              ),
              TextField(
                decoration: _inputDecorations.serverPort,
                controller: portController,
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final newIP = ipController.text;
                final newPort = int.tryParse(portController.text) ?? 5000;
                
                if (newIP != _serverIP || newPort != _serverPort) {
                  setState(() {
                    _serverIP = newIP;
                    _serverPort = newPort;
                    _updateEndpoints();
                  });
                  _testServerConnection();
                }
                
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _updateStoragePath() async {
    await showDialog(
      context: context,
      builder: (context) {
        final pathController = TextEditingController(text: _storagePath);
        return AlertDialog(
          title: const Text('Storage Path Configuration'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: _inputDecorations.storagePath,
                controller: pathController,
              ),
              const SizedBox(height: 10),
              const Text(
                'Enter a valid path on D drive',
                style: TextStyle(color: Colors.blue, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                final newPath = pathController.text.trim();
                if (newPath.isEmpty) {
                  Navigator.of(context).pop();
                  return;
                }
                
                try {
                  final dir = Directory(newPath);
                  if (!await dir.exists()) {
                    await dir.create(recursive: true);
                  }
                  if (await _isDirectoryWritable(newPath)) {
                    setState(() => _storagePath = newPath);
                    _cleanupOldFiles(silent: true);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Storage path updated to $newPath')),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Directory is not writable!')),
                    );
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: ${e.toString().split('\n')[0]}')),
                  );
                }
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showVoiceSettings() async {
    await showDialog(
      context: context,
      builder: (context) {
        String tempVoice = _voice;
        double tempSpeed = _speed;
        
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Voice Settings'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Voice'),
                    value: tempVoice,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => tempVoice = value);
                      }
                    },
                    items: ['default', 'male', 'female']
                        .map((voice) => DropdownMenuItem(
                              value: voice,
                              child: Text(voice.capitalize()),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Speed: '),
                      Expanded(
                        child: Slider(
                          value: tempSpeed,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          label: tempSpeed.toStringAsFixed(1),
                          onChanged: (value) => setState(() => tempSpeed = value),
                        ),
                      ),
                      Text(tempSpeed.toStringAsFixed(1)),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    if (tempVoice != _voice || tempSpeed != _speed) {
                      this.setState(() {
                        _voice = tempVoice;
                        _speed = tempSpeed;
                      });
                    }
                    Navigator.of(context).pop();
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // UI components
  Widget _buildMessageTile(Message message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        padding: const EdgeInsets.all(12.0),
        decoration: BoxDecoration(
          color: message.isUser ? Colors.blue[300] : Colors.grey[300],
          borderRadius: BorderRadius.circular(18.0),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: message.isUser ? Colors.white : Colors.black87,
              ),
            ),
            if (message.audioPath != null) 
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: GestureDetector(
                  onTap: () => _playAudioFile(message.audioPath!),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_circle_outline,
                        size: 16,
                        color: message.isUser ? Colors.white70 : Colors.black54,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Play Audio',
                        style: TextStyle(
                          fontSize: 12,
                          color: message.isUser ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 10,
                    color: message.isUser ? Colors.white70 : Colors.black54,
                  ),
                ),
                if (!message.isUser)
                  IconButton(
                    icon: const Icon(Icons.volume_up, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    color: Colors.black54,
                    onPressed: () => _convertTextToSpeech(message.text),
                    tooltip: 'Play TTS',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: (math.sin((value * 2 * math.pi) + (index * 0.5)) + 1) / 2,
          child: const Text('•', style: TextStyle(fontSize: 20)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Chatbot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            onPressed: _showVoiceSettings,
            tooltip: 'Voice Settings',
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: _updateStoragePath,
            tooltip: 'Storage Settings',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _updateServerConfig,
            tooltip: 'Server Settings',
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            onPressed: () => _cleanupOldFiles(),
            tooltip: 'Clean up old files',
          ),
        ],
      ),
      body: Column(
        children: [
          // Error message banner
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(8.0),
              color: Colors.red[100],
              width: double.infinity,
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red))),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _errorMessage = null),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
// Connection status indicator
          Container(
            color: _isConnected ? _connectionColors.online : _connectionColors.offline,
            padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isConnected ? Icons.cloud_done : Icons.cloud_off,
                  size: 16,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  _isConnected ? 'Server Connected' : 'Server Disconnected',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _testServerConnection,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Test Connection',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          
          // Messages list
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              itemCount: _messages.length + (_isTyping ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < _messages.length) {
                  return _buildMessageTile(_messages[index]);
                } else {
                  // Typing indicator
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 8.0),
                      padding: const EdgeInsets.all(12.0),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(18.0),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildDot(0),
                          _buildDot(1),
                          _buildDot(2),
                        ],
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          
          // Input area
          Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.05),
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: _inputDecorations.messageInput,
                    textCapitalization: TextCapitalization.sentences,
                    enabled: !_isProcessing && _isConnected,
                    onSubmitted: (text) {
                      if (text.trim().isNotEmpty) {
                        _sendMessage(text);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: !_isProcessing && _isConnected
                      ? () {
                          final text = _messageController.text;
                          if (text.trim().isNotEmpty) {
                            _sendMessage(text);
                          }
                        }
                      : null,
                  tooltip: 'Send Message',
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  onPressed: _isProcessing || !_isConnected
                      ? null
                      : _isRecording
                          ? _stopRecording
                          : _startRecording,
                  backgroundColor: _isRecording
                      ? Colors.red
                      : _isProcessing || !_isConnected
                          ? Colors.grey
                          : Theme.of(context).primaryColor,
                  mini: true,
                  child: Icon(
                    _isRecording ? Icons.stop : Icons.mic,
                    color: Colors.white,
                  ),
                  tooltip: _isRecording ? 'Stop Recording' : 'Start Recording',
                ),
              ],
            ),
          ),
          
          // Processing indicator
          if (_isProcessing)
            LinearProgressIndicator(
              backgroundColor: Colors.transparent,
              color: Theme.of(context).primaryColor,
            ),
        ],
      ),
    );
  }
}

// Helper classes for constants
class _ConnectionColors {
  final Color online = Colors.green;
  final Color offline = Colors.red;
  
  const _ConnectionColors();
}

class _InputDecorations {
  final InputDecoration messageInput = const InputDecoration(
    hintText: 'Type a message...',
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(24.0)),
      borderSide: BorderSide.none,
    ),
    filled: true,
    contentPadding: EdgeInsets.symmetric(vertical: 10.0, horizontal: 20.0),
  );
  
  final InputDecoration serverIp = const InputDecoration(
    labelText: 'Server IP',
    hintText: '127.0.0.1',
  );
  
  final InputDecoration serverPort = const InputDecoration(
    labelText: 'Server Port',
    hintText: '5000',
  );
  
  final InputDecoration storagePath = const InputDecoration(
    labelText: 'Storage Path',
    hintText: 'D:\\tts_stt_app_files',
  );
  
  const _InputDecorations();
}         
          //