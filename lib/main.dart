import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fl_chart/fl_chart.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const CaregiverPwaApp());
}

class CaregiverPwaApp extends StatelessWidget {
  const CaregiverPwaApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Caregiver PWA Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        primaryColor: const Color(0xFF1E40AF),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF1E40AF),
          secondary: Color(0xFF10B981),
        ),
      ),
      home: const CaregiverLoginScreen(),
    );
  }
}

class CaregiverLoginScreen extends StatefulWidget {
  const CaregiverLoginScreen({Key? key}) : super(key: key);

  @override
  State<CaregiverLoginScreen> createState() => _CaregiverLoginScreenState();
}

class _CaregiverLoginScreenState extends State<CaregiverLoginScreen> {
  final TextEditingController _patientIdController = TextEditingController();
  bool _isLoading = false;

  void _login() async {
    final patientId = _patientIdController.text.trim();
    if (patientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid Patient UID')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Request FCM push permission for Web
      final messaging = FirebaseMessaging.instance;
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        String? token = await messaging.getToken(
          vapidKey: 'BExfV5W-5gA64hV... (Insert actual Firebase VAPID key here if configured)',
        );
        if (token != null) {
          // Register caregiver FCM token in Firestore under patient's tokens
          await FirebaseFirestore.instance
              .collection('users')
              .doc(patientId)
              .collection('caregiverTokens')
              .doc(token)
              .set({
                'token': token,
                'createdAt': FieldValue.serverTimestamp(),
              });
        }
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CaregiverDashboardScreen(patientId: patientId),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error registering notification services: $e')),
      );
      // Fallback: Proceed to dashboard anyway
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CaregiverDashboardScreen(patientId: patientId),
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 450,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 15,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.healing, size: 64, color: Color(0xFF1E40AF)),
              const SizedBox(height: 16),
              const Text(
                'Caregiver PWA Dashboard',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter Patient UID to monitor adherence & receive missed dose push notifications.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _patientIdController,
                decoration: const InputDecoration(
                  labelText: 'Patient UID',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 24),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _login,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFF1E40AF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Access Dashboard', style: TextStyle(color: Colors.white)),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class CaregiverDashboardScreen extends StatefulWidget {
  final String patientId;
  const CaregiverDashboardScreen({Key? key, required this.patientId}) : super(key: key);

  @override
  State<CaregiverDashboardScreen> createState() => _CaregiverDashboardScreenState();
}

class _CaregiverDashboardScreenState extends State<CaregiverDashboardScreen> {
  int _takenCount = 0;
  int _missedCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  void _loadStats() {
    // Read adherence stats dynamically
    FirebaseFirestore.instance
        .collection('users')
        .doc(widget.patientId)
        .collection('adherenceHistory')
        .snapshots()
        .listen((snapshot) {
      int taken = 0;
      int missed = 0;
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final List takenList = data['taken'] ?? [];
        final List missedList = data['missed'] ?? [];
        taken += takenList.length;
        missed += missedList.length;
      }
      if (mounted) {
        setState(() {
          _takenCount = taken;
          _missedCount = missed;
        });
      }
    });
  }

  double get _adherenceRate {
    final total = _takenCount + _missedCount;
    if (total == 0) return 0;
    return (_takenCount / total) * 100;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Caregiver Monitor | Patient: ${widget.patientId.substring(0, 6)}...'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const CaregiverLoginScreen()),
              );
            },
          )
        ],
      ),
      body: Row(
        children: [
          // Left Sidebar Metrics / Graph
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Adherence Rate Card
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        children: [
                          const Text(
                            'Overall Adherence Rate',
                            style: TextStyle(fontSize: 16, color: Colors.grey, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '${_adherenceRate.toStringAsFixed(1)}%',
                            style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Color(0xFF1E40AF)),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                children: [
                                  const Text('Doses Taken', style: TextStyle(color: Colors.grey)),
                                  Text('$_takenCount', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green)),
                                ],
                              ),
                              Column(
                                children: [
                                  const Text('Doses Missed', style: TextStyle(color: Colors.grey)),
                                  Text('$_missedCount', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red)),
                                ],
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Progress Chart
                  Expanded(
                    child: Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Adherence Analytics Chart',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 24),
                            Expanded(
                              child: PieChart(
                                PieChartData(
                                  sectionsSpace: 4,
                                  centerSpaceRadius: 40,
                                  sections: [
                                    PieChartSectionData(
                                      color: Colors.green,
                                      value: _takenCount.toDouble() == 0 ? 1 : _takenCount.toDouble(),
                                      title: 'Taken',
                                      radius: 60,
                                      titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                    PieChartSectionData(
                                      color: Colors.red,
                                      value: _missedCount.toDouble() == 0 ? 1 : _missedCount.toDouble(),
                                      title: 'Missed',
                                      radius: 60,
                                      titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
          // Vertical divider
          const VerticalDivider(width: 1),
          // Right Sidebar Alerts list
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Real-Time Caregiver Alerts Log',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(widget.patientId)
                          .collection('caregiverAlerts')
                          .orderBy('timestamp', descending: true)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                          return const Center(
                            child: Text('No medication alert logs found.'),
                          );
                        }

                        final docs = snapshot.data!.docs;

                        return ListView.builder(
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final alert = docs[index].data();
                            final time = (alert['timestamp'] as Timestamp?)?.toDate();
                            final formattedTime = time != null
                                ? "${time.day}/${time.month} ${time.hour}:${time.minute.toString().padLeft(2, '0')}"
                                : "Just now";

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              color: const Color(0xFFFEF2F2), // Light red alert background
                              child: ListTile(
                                leading: const Icon(Icons.warning, color: Colors.red),
                                title: Text(
                                  'Missed ${alert['medicineName']}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                                ),
                                subtitle: Text(
                                  'Patient: ${alert['patientName']} | Scheduled: ${alert['doseTiming']}',
                                  style: TextStyle(color: Colors.grey[700]),
                                ),
                                trailing: Text(
                                  formattedTime,
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
