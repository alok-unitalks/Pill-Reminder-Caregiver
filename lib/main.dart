import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:html' as html;
import 'package:shared_preferences/shared_preferences.dart'; // Keep for fallback compilation safety if needed, but we use dart:html
import 'firebase_options.dart';

const String appVersion = "Beta v1.1.2+16";

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
        
        // Synchronous retrieval via window.localStorage (bypasses shared_preferences completely)
        final String? savedPatientUid = html.window.localStorage['caregiver_patient_uid'];
        
        if (savedPatientUid == null) {
          FirebaseAuth.instance.signOut();
          return const CaregiverLoginScreen();
        }
        
        return CaregiverDashboardScreen(patientId: savedPatientUid);
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
  final FocusNode _keyboardFocusNode = FocusNode();
  bool _isLoading = false;
  bool _otpSent = false;
  String? _patientUid;
  ConfirmationResult? _confirmationResult;

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

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

      // Save resolved patient UID early to prevent auth gate race conditions
      html.window.localStorage['caregiver_patient_uid'] = _patientUid!;

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
          html.window.localStorage['caregiver_patient_uid'] = _patientUid!;

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
      body: KeyboardListener(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
            if (!_isLoading) {
              if (_otpSent) {
                _verifyOtp();
              } else {
                _requestOtp();
              }
            }
          }
        },
        child: Stack(
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
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => _requestOtp(),
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
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => _verifyOtp(),
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
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      'Version: $appVersion',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
  String _activeTab = "active-schedule"; // "active-schedule", "adherence-history", "caregiver-alerts"
  final Set<String> _activeReminderIds = {};
  final Set<String> _activeReminderNames = {};
  final Map<String, Map<String, dynamic>> _activeRemindersMap = {};
  
  // Date filters defaulting to 14 days to match the mobile app exactly
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 14));
  DateTime _endDate = DateTime.now();

  // Alerts notification tracking
  int _unreadAlertsCount = 0;
  final Set<String> _notifiedAlertIds = {};

  // Mobile layout navigation index
  int _mobileTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _requestNotificationPermission();
  }

  void _requestNotificationPermission() {
    try {
      if (html.Notification.permission != 'granted' && html.Notification.permission != 'denied') {
        html.Notification.requestPermission();
      }
    } catch (_) {}
  }

  void _triggerBrowserNotification(String medicineName, String patientName) {
    try {
      if (html.Notification.permission == 'granted') {
        html.Notification(
          'Missed Dose Alert ⚠️',
          body: 'Patient $patientName missed scheduled dose of $medicineName.',
        );
      }
    } catch (e) {
      debugPrint("Failed to show HTML5 notification: $e");
    }
  }

  void _loadStats() {
    // Read today's reminders dynamically to match the mobile app's score calculation exactly
    FirebaseFirestore.instance
        .collection('users')
        .doc(widget.patientId)
        .collection('reminders')
        .snapshots()
        .listen((snapshot) {
      int taken = 0;
      int missed = 0;
      final Set<String> activeIds = {};
      final Set<String> activeNames = {};
      final Map<String, Map<String, dynamic>> remindersMap = {};
      
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final id = doc.id;
        remindersMap[id] = data;
        final brandName = (data['brandName'] as String? ?? '').trim().toLowerCase();
        activeIds.add(id);
        if (brandName.isNotEmpty) {
          activeNames.add(brandName);
        }
        if (data['taken'] == true) taken++;
        if (data['missed'] == true) missed++;
      }
      if (mounted) {
        setState(() {
          _takenCount = taken;
          _missedCount = missed;
          _activeReminderIds.clear();
          _activeReminderIds.addAll(activeIds);
          _activeReminderNames.clear();
          _activeReminderNames.addAll(activeNames);
          _activeRemindersMap.clear();
          _activeRemindersMap.addAll(remindersMap);
        });
      }
    });

    // Read caregiver alerts to count unread items and fire browser alerts
    FirebaseFirestore.instance
        .collection('users')
        .doc(widget.patientId)
        .collection('caregiverAlerts')
        .snapshots()
        .listen((snapshot) {
      int unread = 0;
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final alertId = doc.id;
        
        if (data['read'] != true) {
          unread++;
        }
        
        if (!_notifiedAlertIds.contains(alertId)) {
          _notifiedAlertIds.add(alertId);
          final timestamp = (data['timestamp'] as Timestamp?)?.toDate();
          if (timestamp != null && DateTime.now().difference(timestamp).inSeconds < 60) {
            _triggerBrowserNotification(
              data['medicineName'] ?? 'Medication',
              data['patientName'] ?? 'Patient',
            );
          }
        }
      }
      if (mounted) {
        setState(() {
          _unreadAlertsCount = unread;
        });
      }
    });
  }

  double get _adherenceRate {
    final total = _takenCount + _missedCount;
    if (total == 0) return 0;
    return (_takenCount / total) * 100;
  }

  Widget _buildTabButton(String tabId, String label, IconData icon, {int badgeCount = 0}) {
    final isActive = _activeTab == tabId;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = tabId),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isActive ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isActive
                ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: isActive ? const Color(0xFF1E40AF) : Colors.grey[600]),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.black87 : Colors.grey[600],
                ),
              ),
              if (badgeCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                     color: Colors.red,
                     borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$badgeCount',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdherenceRateCard() {
    return Card(
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
    );
  }

  Widget _buildAnalyticsChartCard() {
    return Card(
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
            SizedBox(
              height: 180,
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
    );
  }

  Widget _buildTabSwitcherRow() {
    return Container(
      padding: const EdgeInsets.all(4.0),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _buildTabButton("active-schedule", "Active Schedule", Icons.assignment_outlined),
          _buildTabButton("adherence-history", "Adherence Log", Icons.calendar_today_outlined),
          _buildTabButton("caregiver-alerts", "Caregiver Alerts", Icons.warning_amber_outlined, badgeCount: _unreadAlertsCount),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    if (isMobile) {
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
                html.window.localStorage.remove('caregiver_patient_uid');
                await FirebaseAuth.instance.signOut();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const CaregiverLoginScreen()),
                );
              },
            )
          ],
        ),
        body: _mobileTabIndex == 0
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildAdherenceRateCard(),
                    const SizedBox(height: 16),
                    _buildAnalyticsChartCard(),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        'Version: $appVersion',
                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTabSwitcherRow(),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _buildPanelContent(),
                    ),
                  ],
                ),
              ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _mobileTabIndex,
          onTap: (index) => setState(() => _mobileTabIndex = index),
          selectedItemColor: const Color(0xFF1E40AF),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart),
              label: 'Analytics',
            ),
            BottomNavigationBarItem(
              icon: Stack(
                children: [
                  const Icon(Icons.medical_services),
                  if (_unreadAlertsCount > 0)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 12,
                          minHeight: 12,
                        ),
                        child: Text(
                          '$_unreadAlertsCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 7,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              label: 'Patient Hub',
            ),
          ],
        ),
      );
    } else {
      // Desktop Layout
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
                html.window.localStorage.remove('caregiver_patient_uid');
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildAdherenceRateCard(),
                    const SizedBox(height: 24),
                    _buildAnalyticsChartCard(),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        'Version: $appVersion',
                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Vertical divider
            const VerticalDivider(width: 1),
            // Right Sidebar Adherence Hub
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTabSwitcherRow(),
                    const SizedBox(height: 24),
                    Expanded(
                      child: _buildPanelContent(),
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

  Widget _buildPanelContent() {
    if (_activeTab == "active-schedule") {
      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.patientId)
            .collection('reminders')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text('No active medication schedules found for this patient.'),
            );
          }

          final docs = snapshot.data!.docs;

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final rem = docs[index].data();
              return Card(
                elevation: 1,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: Colors.grey.withOpacity(0.15)),
                ),
                child: ListTile(
                  leading: PillPreviewWidget(
                    shape: rem['shape'] ?? 'round',
                    hexColor: rem['color'] ?? '#1E40AF',
                    size: 20,
                  ),
                  title: Text(
                    rem['brandName'] ?? 'Medication',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  subtitle: Text(
                    "Instruction: ${rem['instructions'] ?? 'As directed'} • ${rem['time'] ?? '08:00 AM'} • Dosage: ${rem['dose'] ?? '1 Unit'}",
                    style: TextStyle(color: Colors.grey[600], fontSize: 12, height: 1.4),
                  ),
                ),
              );
            },
          );
        },
      );
    } else if (_activeTab == "adherence-history") {
      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.patientId)
            .collection('adherenceHistory')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text('No adherence log history found.'),
            );
          }

          // Sort documents by date string descending
          final docs = snapshot.data!.docs.toList()..sort((a, b) => b.id.compareTo(a.id));

          // Filter documents based on Date Selection
          final filteredDocs = docs.where((doc) {
            final dateStr = doc.id;
            final docDate = DateTime.tryParse(dateStr);
            if (docDate == null) return false;
            final cleanDoc = DateTime(docDate.year, docDate.month, docDate.day);
            final cleanStart = DateTime(_startDate.year, _startDate.month, _startDate.day);
            final cleanEnd = DateTime(_endDate.year, _endDate.month, _endDate.day);
            return (cleanDoc.isAtSameMomentAs(cleanStart) || cleanDoc.isAfter(cleanStart)) &&
                   (cleanDoc.isAtSameMomentAs(cleanEnd) || cleanDoc.isBefore(cleanEnd));
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Premium Date Range Selection Card
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.withOpacity(0.15)),
                ),
                child: InkWell(
                  onTap: () async {
                    final selectedRange = await showDateRangePicker(
                      context: context,
                      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
                      firstDate: DateTime.now().subtract(const Duration(days: 90)),
                      lastDate: DateTime.now(),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: Theme.of(context).colorScheme.copyWith(
                              primary: const Color(0xFF1E40AF),
                              onPrimary: Colors.white,
                            ),
                          ),
                          child: child!,
                        );
                      },
                    );
                    if (selectedRange != null) {
                      setState(() {
                        _startDate = selectedRange.start;
                        _endDate = selectedRange.end;
                      });
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E40AF).withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.calendar_today, color: Color(0xFF1E40AF), size: 16),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Select Date Range', style: TextStyle(fontSize: 10, color: Color(0xFF1E40AF), fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              Text(
                                "${_startDate.day}/${_startDate.month}/${_startDate.year} - ${_endDate.day}/${_endDate.month}/${_endDate.year}",
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (filteredDocs.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text('No log events in the selected date period.', style: TextStyle(color: Colors.grey)),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: filteredDocs.length,
                    itemBuilder: (context, index) {
                      final dateDoc = filteredDocs[index];
                      final dateStr = dateDoc.id; // e.g. "2026-08-30"
                      final data = dateDoc.data();
                      
                      final takenList = List<String>.from(data['taken'] ?? []);
                      final missedList = List<String>.from(data['missed'] ?? []);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ...takenList.map((medName) => _buildHistoryItem(medName, true, dateStr)),
                          ...missedList.map((medName) => _buildHistoryItem(medName, false, dateStr)),
                        ],
                      );
                    },
                  ),
                ),
            ],
          );
        },
      );
    } else {
      // Caregiver Alerts Tab
      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
              child: Text('No alerts triggered.'),
            );
          }

          final docs = snapshot.data!.docs;

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final alertId = doc.id;
              final alert = doc.data();
              final bool isRead = alert['read'] == true;
              
              final time = (alert['timestamp'] as Timestamp?)?.toDate();
              final formattedTime = time != null
                  ? "${time.day}/${time.month} ${time.hour}:${time.minute.toString().padLeft(2, '0')}"
                  : "Just now";

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                color: isRead ? Colors.white : const Color(0xFFFEF2F2),
                child: ListTile(
                  leading: Icon(
                    isRead ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                    color: isRead ? Colors.grey : Colors.red,
                  ),
                  title: Text(
                    'Missed ${alert['medicineName']}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isRead ? Colors.grey[700] : Colors.red,
                    ),
                  ),
                  subtitle: Text(
                    'Patient: ${alert['patientName']} | Scheduled: ${alert['doseTiming']} | $formattedTime',
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isRead)
                        IconButton(
                          icon: const Icon(Icons.done, color: Color(0xFF1E40AF), size: 20),
                          tooltip: 'Mark as read',
                          onPressed: () {
                            FirebaseFirestore.instance
                                .collection('users')
                                .doc(widget.patientId)
                                .collection('caregiverAlerts')
                                .doc(alertId)
                                .update({'read': true});
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        tooltip: 'Remove alert',
                        onPressed: () {
                          FirebaseFirestore.instance
                              .collection('users')
                              .doc(widget.patientId)
                              .collection('caregiverAlerts')
                              .doc(alertId)
                              .delete();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }
  }

  Widget _buildHistoryItem(String rawMedName, bool taken, String dateStr) {
    final statusColor = taken ? const Color(0xFF10B981) : Colors.redAccent;
    final statusIcon = taken ? Icons.check_circle_outline : Icons.cancel_outlined;

    // Parse brand name from log string e.g. "rem-123 | Paracetamol" -> "Paracetamol"
    String displayMedName = rawMedName;
    String reminderId = "";
    if (rawMedName.contains('|')) {
      final parts = rawMedName.split('|');
      reminderId = parts[0].trim();
      displayMedName = parts.sublist(1).join('|').trim();
    }

    final String cleanName = displayMedName.trim().toLowerCase();
    
    // Filter: Only display historical logs of reminders that are currently active
    final bool isActive = _activeReminderIds.contains(reminderId) || 
                         _activeReminderNames.contains(cleanName);
                         
    if (!isActive) {
      return const SizedBox.shrink();
    }

    // Try to find the reminder details from our active map
    Map<String, dynamic>? activeRem = _activeRemindersMap[reminderId];
    if (activeRem == null) {
      // Fallback matching by brand name
      for (var rem in _activeRemindersMap.values) {
        if ((rem['brandName'] as String? ?? '').toLowerCase() == cleanName) {
          activeRem = rem;
          break;
        }
      }
    }

    final String timeStr = activeRem != null ? (activeRem['time'] ?? '08:00 AM') : '08:00 AM';
    final String doseStr = activeRem != null ? (activeRem['dose'] ?? '1 Unit') : '1 Unit';
    final String instructionStr = activeRem != null ? (activeRem['instructions'] ?? '') : '';

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.withOpacity(0.15)),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(statusIcon, color: statusColor, size: 24),
        title: Text(
          displayMedName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        subtitle: Text(
          "Logged: $dateStr • Time: $timeStr • Dose: $doseStr${instructionStr.isNotEmpty ? ' • Rule: $instructionStr' : ''}",
          style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            taken ? 'Taken' : 'Missed',
            style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

class PillPreviewWidget extends StatelessWidget {
  final String shape;
  final String hexColor;
  final double size;

  const PillPreviewWidget({
    Key? key,
    required this.shape,
    required this.hexColor,
    this.size = 24.0,
  }) : super(key: key);

  Color _parseColor(String hex) {
    try {
      final buffer = StringBuffer();
      if (hex.length == 6 || hex.length == 7) buffer.write('ff');
      buffer.write(hex.replaceFirst('#', ''));
      return Color(int.parse(buffer.toString(), radix: 16));
    } catch (_) {
      return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(hexColor);
    
    switch (shape.toLowerCase()) {
      case 'oval':
        return Container(
          width: size * 1.5,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.all(Radius.elliptical(size * 1.5, size)),
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
        );
      case 'capsule':
        return Container(
          width: size,
          height: size * 1.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(size),
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
        );
      case 'capsule-split':
        return Container(
          width: size,
          height: size * 1.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(size),
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
          child: Center(
            child: Container(
              width: size,
              height: 1.5,
              color: Colors.white.withOpacity(0.6),
            ),
          ),
        );
      case 'round':
      default:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
        );
    }
  }
}
