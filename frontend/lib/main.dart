import 'package:flutter/material.dart';
import 'dart:math';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:intl/intl.dart';

import 'package:geolocator/geolocator.dart';
// import 'package:geocoding/geocoding.dart'; // ❌ REMOVED: No longer needed

// NEW: Imports for file picking and upload
import 'package:file_picker/file_picker.dart';
import 'package:http_parser/http_parser.dart';

import 'live_view_stub.dart'
    if (dart.library.html) 'live_view_web.dart';

void main() {
  registerLiveFeedView();
  runApp(const AnimalPoachingDashboard());
}

class AnimalPoachingDashboard extends StatelessWidget {
  const AnimalPoachingDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        textTheme: GoogleFonts.montserratTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  Map<String, dynamic> detections = {"humans": 0, "animals": []};
  List<Map<String, dynamic>> history = [];
  Timer? _timer;
  String currentTime = "";
  String _currentAddress = "Fetching location...";

  // --- NEW: State variables for gunshot detection ---
  String _gunshotStatus = "Waiting for audio file...";
  bool _isAnalyzing = false;
  // ---

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _getCurrentLocation();
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
      fetchDetections();
      updateTime();
    });
  }

  // --- NEW: Function to handle audio upload ---
  Future<void> _uploadAndAnalyzeAudio() async {
    try {
      // 1. Pick an audio file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result != null && result.files.first.bytes != null) {
        setState(() {
          _isAnalyzing = true;
          _gunshotStatus = "Analyzing file: ${result.files.first.name}...";
        });

        // 2. Prepare the multipart request
        var uri = Uri.parse("http://localhost:8000/upload_audio");
        var request = http.MultipartRequest("POST", uri);

        // 3. Attach the file
        request.files.add(
          http.MultipartFile.fromBytes(
            'file', // This 'file' key must match the backend (file: UploadFile)
            result.files.first.bytes!,
            filename: result.files.first.name,
            contentType: MediaType('audio', result.files.first.extension ?? 'mp3'),
          ),
        );

        // 4. Send the request
        var streamedResponse = await request.send();
        var response = await http.Response.fromStream(streamedResponse);

        // 5. Handle the response
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          setState(() {
            _gunshotStatus = decoded['result'] ?? "Analysis complete.";
          });
        } else {
          setState(() {
            _gunshotStatus = "Error: ${response.reasonPhrase}";
          });
        }
      } else {
        // User canceled the picker or file was invalid
        setState(() {
          _gunshotStatus = "File selection canceled.";
        });
      }
    } catch (e) {
      print("Error uploading file: $e");
      setState(() {
        _gunshotStatus = "Error: $e";
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }
  // --- End of new function ---

  // --- ⬇️ UPDATED FUNCTION ⬇️ ---
  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // 1. Check if location services are enabled
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _currentAddress = "Location services are disabled.";
      });
      return;
    }

    // 2. Check and request permissions
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _currentAddress = "Location permissions are denied.";
        });
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _currentAddress = "Location permissions are permanently denied.";
      });
      return;
    }

    // 3. Get the coordinates (with medium accuracy for web)
    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);

      // 4. 💡 NEW: Call OUR OWN backend API to bypass CORS
      final url = Uri.parse(
          "http://localhost:8000/reverse_geocode?lat=${position.latitude}&lon=${position.longitude}");
      
      // No headers needed here, since our backend handles it
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // The data structure is the same because our backend just forwards it
        final address = data['address'];
        final locality = address['city'] ?? address['town'] ?? address['village'] ?? '';
        final state = address['state'] ?? '';

        if (locality.isNotEmpty) {
          setState(() {
            _currentAddress = "📍 $locality, $state";
          });
        } else {
          // Fallback if address is weird
          setState(() {
             _currentAddress = "📍 Coimbatore: ${position.latitude.toStringAsFixed(2)}, ${position.longitude.toStringAsFixed(2)}";
          });
        }
      } else {
        // Our backend API call failed
        setState(() {
           _currentAddress = "Error: Could not get address.";
           print("Failed to reverse geocode: ${response.body}");
        });
      }

    } catch (e) {
      print(e);
      setState(() {
        _currentAddress = "Could not fetch location.";
      });
    }
  }
  // --- ⬆️ END OF UPDATED FUNCTION ⬆️ ---


  @override
  void dispose() {
    _controller.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void updateTime() {
    final now = DateTime.now();
    setState(() {
      currentTime = DateFormat("EEEE, MMM d • hh:mm:ss a").format(now);
    });
  }

  Future<void> fetchDetections() async {
    // ... (This function is unchanged) ...
    try {
      final response =
          await http.get(Uri.parse("http://localhost:8000/detections"));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        if (decoded["humans"] != detections["humans"] ||
            !_listEquals(decoded["animals"], detections["animals"])) {
          history.insert(0, {
            "time": DateFormat("hh:mm:ss a").format(DateTime.now()),
            "humans": decoded["humans"],
            "animals": List<String>.from(decoded["animals"]),
          });
          if (history.length > 50) {
            history.removeLast();
          }
        }

        setState(() {
          detections = decoded;
        });
      }
    } catch (e) {
      print("Failed to fetch detections: $e");
    }
  }

  bool _listEquals(List a, List b) {
    // ... (This function is unchanged) ...
    if (a.length != b.length) return false;
    a.sort();
    b.sort();
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                painter: MovingBackgroundPainter(_controller.value),
                child: Container(),
              );
            },
          ),
          SafeArea(
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    border: Border(bottom: BorderSide(color: Colors.white24)),
                  ),
                  child: Row(
                    // ... (Top Bar is unchanged) ...
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "🛡️ WildEye Protection Dashboard",
                        style: GoogleFonts.oswald(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            currentTime,
                            style: GoogleFonts.montserrat(
                              fontSize: 16,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 4),
                          // --- ⬇️ UPDATED WIDGET ⬇️ ---
                          Text(
                            _currentAddress,
                            style: GoogleFonts.montserrat(
                              fontSize: 14,
                              // Change color if it's an error
                              color: _currentAddress.startsWith("📍")
                                  ? Colors.cyanAccent
                                  : Colors.redAccent,
                            ),
                          ),
                          // --- ⬆️ END OF UPDATED WIDGET ⬆️ ---
                        ],
                      )
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 250,
                          // --- ⬇️ UPDATED THIS SECTION ⬇️ ---
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                _buildStatCard(
                                  "🚨 Humans",
                                  "${detections["humans"]}",
                                  Colors.yellow,
                                ),
                                _buildStatCard(
                                  "🐘 Elephants",
                                  "${detections["animals"].where((a) => a == 'elephant').length}",
                                  Colors.greenAccent,
                                ),
                                _buildStatCard(
                                  "🐅 Tigers",
                                  "${detections["animals"].where((a) => a == 'tiger').length}",
                                  Colors.redAccent,
                                ),
                                
                                // --- ⬇️ ADDED THESE NEW CARDS ⬇️ ---
                                _buildStatCard(
                                  "🐻 Bears",
                                  "${detections["animals"].where((a) => a == 'bear').length}",
                                  Colors.brown.shade300,
                                ),
                                _buildStatCard(
                                  "🦓 Zebras",
                                  "${detections["animals"].where((a) => a == 'zebra').length}",
                                  Colors.grey.shade400,
                                ),
                                _buildStatCard(
                                  "🦒 Giraffes",
                                  "${detections["animals"].where((a) => a == 'giraffe').length}",
                                  Colors.orange.shade300,
                                ),
                                // --- ⬆️ END OF NEW CARDS ⬆️ ---

                                _buildStatCard(
                                  "⚠️ Total Intrusions",
                                  (detections["humans"] +
                                          (detections["animals"] as List).length)
                                      .toString(),
                                  Colors.orange,
                                ),
                                _buildGunshotDetectorCard(),
                              ],
                            ),
                          ),
                          // --- ⬆️ END OF UPDATED SECTION ⬆️ ---
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: Column(
                            // ... (Live Feed and History sections are unchanged) ...
                            children: [
                              Expanded(
                                flex: 3,
                                child: _buildSectionContainer(
                                  title: "📹 Live Camera Feed",
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: buildLiveFeed(),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                flex: 2,
                                child: _buildSectionContainer(
                                  title: "📋 Detection History",
                                  child: history.isEmpty
                                      ? const Center(
                                          child: Text("No detections yet..."))
                                      : ListView.builder(
                                          itemCount: history.length,
                                          itemBuilder: (context, index) {
                                            final entry = history[index];
                                            final animals =
                                                (entry["animals"] as List)
                                                    .join(', ');
                                            return ListTile(
                                              leading: Text(
                                                entry["time"],
                                                style: GoogleFonts.inconsolata(
                                                    color: Colors.white70),
                                              ),
                                              title: Text(
                                                  "👤 ${entry["humans"]} Humans"),
                                              trailing: Text(
                                                "🐾 Animals: ${animals.isEmpty ? 'None' : animals}",
                                                style: const TextStyle(
                                                    color: Colors.white),
                                              ),
                                            );
                                          },
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- NEW: Widget for the Gunshot Detector Card ---
  Widget _buildGunshotDetectorCard() {
    return Card(
      color: Colors.white.withOpacity(0.1),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white24),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "🔬 Gunshot Analysis",
              style: GoogleFonts.oswald(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            // Status Text
            Text(
              _gunshotStatus,
              style: GoogleFonts.montserrat(
                color: _gunshotStatus.contains("detected")
                    ? Colors.redAccent
                    : Colors.white70,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            // Upload Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _isAnalyzing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.upload_file, size: 16),
                label: Text(_isAnalyzing ? "ANALYZING..." : "UPLOAD AUDIO"),
                onPressed: _isAnalyzing ? null : _uploadAndAnalyzeAudio,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent.withOpacity(0.8),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.withOpacity(0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  // --- End of new widget ---


  Widget _buildStatCard(String title, String value, Color indicatorColor) {
    // ... (This widget is unchanged) ...
    return Card(
      color: Colors.white.withOpacity(0.1),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white24),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: GoogleFonts.oswald(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(width: 12, height: 12, color: indicatorColor),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: GoogleFonts.montserrat(
                color: indicatorColor,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionContainer({required String title, required Widget child}) {
    // ... (This widget is unchanged) ...
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.oswald(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const Divider(color: Colors.white24, height: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class MovingBackgroundPainter extends CustomPainter {
  // ... (This class is unchanged) ...
  final double progress;
  MovingBackgroundPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..shader = LinearGradient(
        colors: [const Color(0xFF0D1B2A), const Color(0xFF1B263B)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    final wavePaint = Paint()
      ..color = Colors.white.withOpacity(0.03)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final path = Path();
    for (double x = 0; x <= size.width; x++) {
      path.lineTo(
        x,
        size.height / 2 +
            50 * sin((x / size.width * 2 * pi) + (progress * 2 * pi)),
      );
    }
    canvas.drawPath(path, wavePaint);
  }

  @override
  bool shouldRepaint(covariant MovingBackgroundPainter oldDelegate) => true;
}