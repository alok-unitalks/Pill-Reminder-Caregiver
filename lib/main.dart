import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        
        final user = snapshot.data;
        if (user == null) {
          return const CaregiverLoginScreen();
        }
        
        return FutureBuilder<SharedPreferences>(
          future: SharedPreferences.getInstance(),
          builder: (context, prefSnapshot) {
            if (prefSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            
            if (prefSnapshot.hasError || !prefSnapshot.hasData) {
              FirebaseAuth.instance.signOut();
              return const CaregiverLoginScreen();
            }
            
            final prefs = prefSnapshot.data!;
            final savedPatientUid = prefs.getString('caregiver_patient_uid');
            
            if (savedPatientUid == null) {
              FirebaseAuth.instance.signOut();
              return const CaregiverLoginScreen();
            }
            
            return CaregiverDashboardScreen(patientId: savedPatientUid);
          },
        );
      },
    );
  }
}

class CaregiverLoginScreen extends StatefulWidget {
  const CaregiverLoginScreen({Key? key}) : super(key: key);

  @override
  State<CaregiverLoginScreen> createState() => _CaregiverLoginScreenState();
}

class _CaregiverLoginScreenState extends State<CaregiverLoginScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  bool _isLoading = false;
  bool _otpSent = false;
  String? _patientUid;
  ConfirmationResult? _confirmationResult;

  // Search caregiverPhone in Firestore, send SMS OTP
  void _requestOtp() async {
    final enteredPhone = _phoneController.text.trim();
    if (enteredPhone.isEmpty || enteredPhone.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid 10-digit phone number')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Extrapolate raw 10 digits
      String rawPhone = enteredPhone.replaceAll(RegExp(r'\D'), '');
      if (rawPhone.length > 10) {
        rawPhone = rawPhone.substring(rawPhone.length - 10);
      }

      // Query database: find user where caregiverPhone matches variations of the number
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('caregiverPhone', whereIn: [rawPhone, '+91$rawPhone', '91$rawPhone'])
          .get();

      if (query.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error: This phone number is not registered as a caregiver.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isLoading = false);
        return;
      }

      // Found patient link!
      _patientUid = query.docs.first.id;
      final String patientName = query.docs.first.data()['name'] ?? 'Patient';

      // Send Firebase OTP using reCAPTCHA
      final ConfirmationResult result = await FirebaseAuth.instance.signInWithPhoneNumber(
        '+91$rawPhone',
        RecaptchaVerifier(
          auth: FirebaseAuthPlatform.instance,
        ),
      );

      setState(() {
        _confirmationResult = result;
        _otpSent = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Verification code sent for patient $patientName'),
          backgroundColor: const Color(0xFF1E40AF),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error sending SMS OTP: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // Verify OTP and transition to Dashboard
  void _verifyOtp() async {
    final enteredOtp = _otpController.text.trim();
    if (enteredOtp.isEmpty || enteredOtp.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the 6-digit verification code')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_confirmationResult != null && _patientUid != null) {
        // Authenticate credentials
        UserCredential userCredential = await _confirmationResult!.confirm(enteredOtp);
        
        if (userCredential.user != null) {
          // Subscribe to notifications (fail-safe fallback configured)
          try {
            final messaging = FirebaseMessaging.instance;
            NotificationSettings settings = await messaging.requestPermission(
              alert: true,
              sound: true,
            );

            if (settings.authorizationStatus == AuthorizationStatus.authorized) {
              String? token = await messaging.getToken();
              if (token != null) {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(_patientUid)
                    .collection('caregiverTokens')
                    .doc(token)
                    .set({
                      'token': token,
                      'createdAt': FieldValue.serverTimestamp(),
                    });
              }
            }
          } catch (e) {
            debugPrint("Notification permission bypassed: $e");
          }

          // Save session state locally
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('caregiver_patient_uid', _patientUid!);
          } catch (prefError) {
            debugPrint("SharedPreferences write failed, session won't persist: $prefError");
          }

          // Navigate to dashboard
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => CaregiverDashboardScreen(patientId: _patientUid!),
            ),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invalid code: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Center(
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
                    'Caregiver Verification Portal',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _otpSent
                        ? 'Enter the 6-digit code sent to your registered phone number.'
                        : 'Enter your registered phone number to verify identity and access the patient dashboard.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  if (!_otpSent) ...[
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.phone),
                        prefixText: '+91 ',
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Verification Code',
                        hintText: '123456',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.security),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton(
                          onPressed: _otpSent ? _verifyOtp : _requestOtp,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: const Color(0xFF1E40AF),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text(
                            _otpSent ? 'Verify Code' : 'Send Verification Code',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                  if (_otpSent) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _otpSent = false;
                          _otpController.clear();
                        });
                      },
                      child: const Text('Back to phone entry', style: TextStyle(color: Color(0xFF1E40AF))),
                    )
                  ]
                ],
              ),
            ),
          ),
        ],
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
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('caregiver_patient_uid');
              await FirebaseAuth.instance.signOut();
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
