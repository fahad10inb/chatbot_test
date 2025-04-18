import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path/path.dart' as path;

void main() {
  runApp(const ChatbotApp());
}

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

  Message({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.audioPath,
  });
}

class _ChatbotHomePageState extends State<ChatbotHomePage> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Message> _messages = [];
  
  String _voice = 'default';
  double _speed = 1.0;
  bool _isRecording = false;
  bool _isProcessing = false;
  String? _errorMessage;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Record _record = Record();
  String? _audioPath;
  bool _isConnected = true;
  bool _isTyping = false;
  
  // Storage directory - setting D drive path
  String _storagePath = 'D:\\tts_stt_app_files';
  
  // Server configuration
  String _serverIP = '192.168.1.84';
  int _serverPort = 5000;
  String get _ttsApiUrl => 'http://$_serverIP:$_serverPort/api/convert';
  String get _sttApiUrl => 'http://$_serverIP:$_serverPort/api/transcribe';

  @override
  void initState() {
    super.initState();
    _initializeApp();
    
    // Add welcome message
    _messages.add(Message(
      text: "Hello! I'm your voice assistant. Type a message or tap the microphone to speak.",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> _initializeApp() async {
    await _setupStorage();
    _checkConnectivity();
    
    // Set up a periodic connectivity check
    Timer.periodic(const Duration(seconds: 10), (timer) {
      _checkConnectivity();
    });
  }

  // Initialize storage - use D drive
  Future<void> _setupStorage() async {
    try {
      // Create the D drive directory if it doesn't exist
      final dDriveDir = Directory(_storagePath);
      if (!await dDriveDir.exists()) {
        await dDriveDir.create(recursive: true);
      }
      
      // Check if the directory is writable
      if (await _isDirectoryWritable(_storagePath)) {
        debugPrint("Using D drive storage path: $_storagePath");
      } else {
        throw Exception('D drive storage path is not writable');
      }
      
      setState(() {});
    } catch (e) {
      debugPrint("Error setting up D drive storage: $e");
      // Fall back to app documents directory as a last resort
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final appAudioDir = Directory(path.join(appDir.path, 'audio_files'));
        if (!await appAudioDir.exists()) {
          await appAudioDir.create(recursive: true);
        }
        _storagePath = appAudioDir.path;
        debugPrint("Fallback to app directory: $_storagePath");
        setState(() {
          _errorMessage = 'Failed to use D drive. Using app directory instead: $_storagePath';
        });
      } catch (e2) {
        // If app directory also fails, try temp directory
        try {
          final tempDir = await getTemporaryDirectory();
          _storagePath = tempDir.path;
          debugPrint("Fallback to temp directory: $_storagePath");
          setState(() {
            _errorMessage = 'Failed to use D drive and app directory. Using temp directory: $_storagePath';
          });
        } catch (e3) {
          setState(() {
            _errorMessage = 'Failed to initialize storage: $e3';
          });
        }
      }
    }
  }

  // Check if directory is writable by attempting to create a test file
  Future<bool> _isDirectoryWritable(String dirPath) async {
    try {
      final directory = Directory(dirPath);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      
      // Try to write a test file
      final testFile = File(path.join(dirPath, 'write_test_${DateTime.now().millisecondsSinceEpoch}.tmp'));
      await testFile.writeAsString('Test write');
      await testFile.delete(); // Clean up
      
      debugPrint("Directory is writable: $dirPath");
      return true;
    } catch (e) {
      debugPrint("Directory is not writable: $dirPath, Error: $e");
      return false;
    }
  }

  Future<bool> _createDirectory(String dirPath) async {
    try {
      final directory = Directory(dirPath);
      await directory.create(recursive: true);
      debugPrint("Created directory: $dirPath");
      return true;
    } catch (e) {
      debugPrint("Error creating directory: $e");
      return false;
    }
  }

  Future<void> _checkConnectivity() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    setState(() {
      _isConnected = connectivityResult != ConnectivityResult.none;
    });
    
    if (_isConnected) {
      _checkServerConnection();
    }
  }

  Future<void> _checkServerConnection() async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(
        Uri.parse('http://$_serverIP:$_serverPort/'),
      ).timeout(const Duration(seconds: 5));
      
      debugPrint("Server connection test result: ${response.statusCode}");
      setState(() {
        _isConnected = response.statusCode == 200;
        _errorMessage = response.statusCode == 200 
            ? null 
            : 'Server responded but no health endpoint: ${response.statusCode}';
      });
    } catch (e) {
      setState(() {
        _isConnected = false;
        _errorMessage = 'Server connection failed: ${e.toString()}';
      });
      debugPrint("Server connection test failed: $e");
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _record.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
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

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    
    // Add user message to chat
    setState(() {
      _messages.add(Message(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _messageController.clear();
    });
    
    _scrollToBottom();
    
    // Set typing indicator
    setState(() {
      _isTyping = true;
    });
    
    // Simulate bot thinking (in a real app, this would be a call to a chatbot API)
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Example response for demonstration - in a real app, this would come from a chatbot backend
    final response = "I received your message: \"$text\". How can I help you with that?";
    
    // Add bot response
    setState(() {
      _isTyping = false;
      _messages.add(Message(
        text: response,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
    
    _scrollToBottom();
    
    // Convert bot's response to speech
    await _convertTextToSpeech(response);
  }

  Future<void> _convertTextToSpeech([String? textToConvert]) async {
    final text = textToConvert ?? _messages.last.text;
    
    if (!_isConnected) {
      setState(() {
        _errorMessage = 'No internet connection. Please check your network.';
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      // Clean up previous audio resources first
      await _audioPlayer.stop();
      await _audioPlayer.release();
      debugPrint("Audio player stopped and released");
      
      debugPrint("Sending request to $_ttsApiUrl with text: $text, voice: $_voice, speed: $_speed");
      final response = await http.post(
        Uri.parse(_ttsApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': text,
          'voice': _voice,
          'speed': _speed,
        }),
      ).timeout(const Duration(seconds: 20));
      
      debugPrint("Received response with status: ${response.statusCode}, body length: ${response.bodyBytes.length}");
      if (response.statusCode == 200) {
        // Generate a unique filename using timestamp
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final audioFilePath = path.join(_storagePath, 'speech_$timestamp.wav');
        final audioFile = File(audioFilePath);
        
        // Ensure directory exists before writing
        final directory = Directory(path.dirname(audioFilePath));
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        
        await audioFile.writeAsBytes(response.bodyBytes);
        debugPrint("Audio file saved to: ${audioFile.path}, size: ${await audioFile.length()} bytes");
        
        // Update the last bot message with audio path
        if (_messages.isNotEmpty && !_messages.last.isUser) {
          final lastIndex = _messages.length - 1;
          final lastMessage = _messages[lastIndex];
          setState(() {
            _messages[lastIndex] = Message(
              text: lastMessage.text,
              isUser: lastMessage.isUser,
              timestamp: lastMessage.timestamp,
              audioPath: audioFile.path,
            );
          });
        }
        
        // Verify file exists before playing
        if (await audioFile.exists()) {
          debugPrint("File exists and is ready to play");
          await _audioPlayer.play(DeviceFileSource(audioFile.path));
          debugPrint("Audio playback started for: ${audioFile.path}");
          setState(() {
            _audioPath = audioFile.path;
          });
        } else {
          throw Exception('Failed to save audio file');
        }
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception(errorData['message'] ?? 'Failed to convert text to speech');
      }
    } on FileSystemException catch (e) {
      debugPrint("File system exception: $e");
      setState(() {
        _errorMessage = 'File error: ${e.message}. Error code: ${e.osError?.errorCode}';
      });
    } on SocketException catch (e) {
      debugPrint("Socket exception: $e");
      setState(() {
        _errorMessage = 'Connection error: Server might be offline. Try checking firewall settings.';
      });
    } on TimeoutException catch (e) {
      debugPrint("Timeout exception: $e");
      setState(() {
        _errorMessage = 'Connection timed out: Server is taking too long to respond';
      });
    } catch (e) {
      debugPrint("Error occurred: $e");
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _playMessageAudio(String audioPath) async {
    try {
      // Stop any current playback
      await _audioPlayer.stop();
      await _audioPlayer.release();
      
      // Play the audio file
      await _audioPlayer.play(DeviceFileSource(audioPath));
    } catch (e) {
      debugPrint("Error playing audio: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing audio: $e')),
      );
    }
  }

  Future<void> _startRecording() async {
    if (!_isConnected) {
      setState(() {
        _errorMessage = 'No internet connection. Please check your network.';
      });
      return;
    }

    if (await Permission.microphone.request().isGranted) {
      setState(() {
        _isRecording = true;
        _errorMessage = null;
      });

      try {
        // Generate a unique filename for recording
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final audioFilePath = path.join(_storagePath, 'recording_$timestamp.m4a');
        
        // Ensure directory exists
        final directory = Directory(path.dirname(audioFilePath));
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        
        debugPrint("Starting recording to: $audioFilePath");
        
        // Verify path is valid before recording
        final pathDirectory = Directory(path.dirname(audioFilePath));
        if (!await pathDirectory.exists()) {
          throw Exception('Recording directory does not exist and could not be created');
        }
        
        await _record.start(
          path: audioFilePath,
          encoder: AudioEncoder.aacLc, // Using AAC encoding for m4a
          bitRate: 128000,
          samplingRate: 44100,
        );
      } catch (e) {
        debugPrint("Error starting recording: $e");
        setState(() {
          _isRecording = false;
          _errorMessage = 'Failed to start recording: $e';
        });
      }
    } else {
      setState(() {
        _errorMessage = 'Microphone permission denied';
      });
    }
  }

  Future<void> _stopRecording() async {
    setState(() {
      _isRecording = false;
      _isProcessing = true;
    });

    try {
      final recordedPath = await _record.stop();
      debugPrint("Recording stopped, path: $recordedPath");
      
      if (recordedPath != null) {
        // Store the path for reference
        _audioPath = recordedPath;
        
        // Create a new File object with the path
        final audioFile = File(recordedPath);
        
        // Debug file info
        if (await audioFile.exists()) {
          final fileSize = await audioFile.length();
          debugPrint("Recording file exists: ${audioFile.path}, size: $fileSize bytes");
          
          // Wait a moment to ensure file is completely written
          await Future.delayed(const Duration(milliseconds: 500));
          
          // Make a copy in D drive if not already there
          String transcriptionPath = recordedPath;
          if (!recordedPath.startsWith(_storagePath)) {
            final timestamp = DateTime.now().millisecondsSinceEpoch;
            final dDrivePath = path.join(_storagePath, 'recording_copy_$timestamp.m4a');
            
            try {
              final dDriveFile = await audioFile.copy(dDrivePath);
              transcriptionPath = dDriveFile.path;
              debugPrint("Copied recording to D drive: $transcriptionPath");
            } catch (e) {
              debugPrint("Error copying file to D drive, using original: $e");
              // Continue with original path
            }
          }
          
          // Use the file for transcription
          await _transcribeAudio(File(transcriptionPath));
        } else {
          debugPrint("Recording file does not exist: $recordedPath");
          
          // Try to diagnose the issue by checking directory
          final directory = Directory(path.dirname(recordedPath));
          final dirExists = await directory.exists();
          debugPrint("Directory exists: $dirExists at ${directory.path}");
          
          if (dirExists) {
            final dirContents = directory.listSync();
            debugPrint("Directory contents: ${dirContents.map((e) => e.path).join(', ')}");
          }
          
          setState(() {
            _errorMessage = 'Recording file not found at $recordedPath. Directory exists: $dirExists';
            _isProcessing = false;
          });
        }
      } else {
        debugPrint("No recording path returned");
        setState(() {
          _errorMessage = 'No recording available';
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint("Error stopping recording: $e");
      setState(() {
        _errorMessage = 'Recording error: $e';
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
      debugPrint("Sending transcription request to $_sttApiUrl with file: ${audioFile.path}");
      var request = http.MultipartRequest('POST', Uri.parse(_sttApiUrl));
      
      // Log file details before sending
      final fileSize = await audioFile.length();
      debugPrint("File size: $fileSize bytes");
      
      if (fileSize == 0) {
        throw Exception('Audio file is empty (0 bytes)');
      }
      
      request.files.add(await http.MultipartFile.fromPath('audio', audioFile.path));
      
      final streamedResponse = await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamedResponse);
      debugPrint("Received transcription response with status: ${response.statusCode}");

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        final transcript = result['transcript'] ?? 'No transcription available';
        debugPrint("Transcription result: $transcript");
        
        // Add the transcription to the messages as a user message
        if (transcript.isNotEmpty && transcript != 'No transcription available') {
          setState(() {
            _messages.add(Message(
              text: transcript,
              isUser: true,
              timestamp: DateTime.now(),
              audioPath: audioFile.path,
            ));
          });
          
          _scrollToBottom();
          
          // Process the transcribed message as user input
          await _sendMessage(transcript);
        } else {
          setState(() {
            _errorMessage = 'Could not transcribe audio. Please try again.';
          });
        }
      } else {
        debugPrint("Error response body: ${response.body}");
        final errorData = jsonDecode(response.body);
        throw Exception(errorData['message'] ?? 'Failed to transcribe audio');
      }
    } on SocketException catch (e) {
      debugPrint("Socket exception during transcription: $e");
      setState(() {
        _errorMessage = 'Connection error: Server might be offline';
      });
    } on TimeoutException catch (e) {
      debugPrint("Timeout exception during transcription: $e");
      setState(() {
        _errorMessage = 'Transcription timed out: Server is taking too long to respond';
      });
    } catch (e) {
      debugPrint("Error during transcription: $e");
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _testServerConnection() async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(
        Uri.parse('http://$_serverIP:$_serverPort/'),
      ).timeout(const Duration(seconds: 5));
      
      debugPrint("Server connection test result: ${response.statusCode}");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Server is online: ${response.statusCode}')),
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Server connection failed: ${e.toString()}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Server connection failed: ${e.toString()}')),
      );
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  // Cleanup method to delete old files
  Future<void> _cleanupOldFiles() async {
    try {
      final directory = Directory(_storagePath);
      if (await directory.exists()) {
        // Get all files in the directory
        final files = directory.listSync();
        
        // Current time
        final now = DateTime.now();
        
        // Keep track of deleted files
        int deletedCount = 0;
        
        // Check each file
        for (var file in files) {
          if (file is File) {
            // Get file stats
            final stat = file.statSync();
            final fileAge = now.difference(stat.modified);
            
            // Delete files older than 1 hour
            if (fileAge.inHours > 1) {
              await file.delete();
              deletedCount++;
              debugPrint("Deleted old file: ${file.path}");
            }
          }
        }
        
        if (deletedCount > 0) {
          debugPrint("Cleaned up $deletedCount old files");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cleaned up $deletedCount old files')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No old files to clean up')),
          );
        }
      }
    } catch (e) {
      debugPrint("Error cleaning up old files: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error cleaning up files: $e')),
      );
    }
  }

  Future<void> _updateServerConfig() async {
    await showDialog(
      context: context,
      builder: (context) {
        // Use TextEditingController instead of initialValue
        final ipController = TextEditingController(text: _serverIP);
        final portController = TextEditingController(text: _serverPort.toString());
        
        return AlertDialog(
          title: const Text('Server Configuration'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Server IP'),
                controller: ipController,
              ),
              TextField(
                decoration: const InputDecoration(labelText: 'Server Port'),
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
                setState(() {
                  _serverIP = ipController.text;
                  _serverPort = int.tryParse(portController.text) ?? 5000;
                });
                Navigator.of(context).pop();
                _testServerConnection();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  // Update storage path - with D drive priority
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
                decoration: const InputDecoration(
                  labelText: 'Storage Path',
                  hintText: 'D:\\your_folder_path',
                ),
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final newPath = pathController.text.trim();
                
                if (newPath.isEmpty) {
                  // Default to D drive
                  setState(() {
                    _storagePath = 'D:\\tts_stt_app_files';
                  });
                } else {
                  // Try to use provided path
                  try {
                    final dir = Directory(newPath);
                    if (!await dir.exists()) {
                      await dir.create(recursive: true);
                    }
                    
                    // Test writing
                    if (await _isDirectoryWritable(newPath)) {
                      setState(() {
                        _storagePath = newPath;
                      });
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Directory is not writable!')),
                      );
                    }
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
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
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Voice Settings'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Voice selection
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Voice'),
                    value: _voice,
                    onChanged: (value) {
                      setState(() {
                        _voice = value!;
                      });
                    },
                    items: ['default', 'male', 'female']
                        .map((voice) => DropdownMenuItem(
                              value: voice,
                              child: Text(voice.capitalize()),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  // Speed selection
                  Row(
                    children: [
                      const Text('Speed: '),
                      Expanded(
                        child: Slider(
                          value: _speed,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          label: _speed.toStringAsFixed(1),
                          onChanged: (value) {
                            setState(() {
                              _speed = value;
                            });
                          },
                        ),
                      ),
                      Text(_speed.toStringAsFixed(1)),
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
                    // Update the parent state
                    this.setState(() {
                      // Values from dialog are already updated
                    });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Chatbot'),
        actions: [
          // Voice settings
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            onPressed: _showVoiceSettings,
            tooltip: 'Voice Settings',
          ),
          // Storage settings
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: _updateStoragePath,
            tooltip: 'Storage Settings',
          ),
          // Server settings
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _updateServerConfig,
            tooltip: 'Server Settings',
          ),
          // Cleanup
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            onPressed: _cleanupOldFiles,
            tooltip: 'Clean up old files',
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection status indicator
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            color: _isConnected ? Colors.green[100] : Colors.red[100],
            child: Row(
              children: [
                Icon(
                  _isConnected ? Icons.wifi : Icons.wifi_off,
                  color: _isConnected ? Colors.green : Colors.red,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? 'Connected' : 'No connection',
                  style: TextStyle(
                    color: _isConnected ? Colors.green[800] : Colors.red[800],
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _isProcessing ? null : _testServerConnection,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    minimumSize: const Size(0, 0),
textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: const Text('Test Server'),
                )
              ],
            ),
          ),
          
          // Error message
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(8.0),
              color: Colors.yellow[100],
              width: double.infinity,
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Colors.red[800], fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          
          // Messages list
          Expanded(
            child: _messages.isEmpty
              ? const Center(child: Text('No messages yet'))
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8.0),
                  itemCount: _messages.length + (_isTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    // Show typing indicator as the last item when needed
                    if (_isTyping && index == _messages.length) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 8.0),
                          padding: const EdgeInsets.all(12.0),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(18.0),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                                ),
                              ),
                              SizedBox(width: 8),
                              Text('Typing...', style: TextStyle(color: Colors.black54)),
                            ],
                          ),
                        ),
                      );
                    }
                    
                    // Regular message
                    final message = _messages[index];
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
                                  onTap: () => _playMessageAudio(message.audioPath!),
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
                                        'Play audio',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: message.isUser ? Colors.white70 : Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(
                                '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: message.isUser ? Colors.white70 : Colors.black54,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
          ),
          
          // Recording indicator
          if (_isRecording)
            Container(
              padding: const EdgeInsets.all(8.0),
              color: Colors.red[100],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mic, color: Colors.red),
                  const SizedBox(width: 8),
                  Text(
                    'Recording...',
                    style: TextStyle(color: Colors.red[800]),
                  ),
                ],
              ),
            ),
          
          // Processing indicator  
          if (_isProcessing && !_isRecording)
            const LinearProgressIndicator(
              backgroundColor: Colors.transparent,
            ),
          
          // Message input area
          Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  spreadRadius: 1,
                  blurRadius: 3,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24.0)),
                      ),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (text) {
                      if (text.trim().isNotEmpty) {
                        _sendMessage(text);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Send button
                FloatingActionButton(
                  onPressed: () {
                    if (_messageController.text.trim().isNotEmpty) {
                      _sendMessage(_messageController.text);
                    }
                  },
                  mini: true,
                  child: const Icon(Icons.send),
                ),
                const SizedBox(width: 8),
                // Record button
                FloatingActionButton(
                  onPressed: _isRecording ? _stopRecording : _startRecording,
                  backgroundColor: _isRecording ? Colors.red : null,
                  mini: true,
                  child: Icon(_isRecording ? Icons.stop : Icons.mic),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Extension to capitalize strings
extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}                    