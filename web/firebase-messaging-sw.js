// Import and configure the Firebase SDK
// These scripts are made available when the app is served or built
importScripts("https://www.gstatic.com/firebasejs/9.22.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/9.22.0/firebase-messaging-compat.js");

// Initialize the Firebase app in the service worker by passing in
// your app's Firebase config object
firebase.initializeApp({
  apiKey: "AIzaSyDq2YZFKY5rBVrKD2Tr8DnUPOveoKOM3UI",
  authDomain: "remindrx-631f8.firebaseapp.com",
  projectId: "remindrx-631f8",
  storageBucket: "remindrx-631f8.firebasestorage.app",
  messagingSenderId: "1032931526089",
  appId: "1:1032931526089:web:cf6922402d9bef22d8d418"
});

// Retrieve an instance of Firebase Messaging so that it can handle background messages.
const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  console.log('[firebase-messaging-sw.js] Received background message ', payload);
  
  const notificationTitle = payload.notification ? payload.notification.title : 'Missed Medication Alert';
  const notificationOptions = {
    body: payload.notification ? payload.notification.body : 'A patient has missed their scheduled dose.',
    icon: '/favicon.png',
    data: payload.data,
  };

  self.registration.showNotification(notificationTitle, notificationOptions);
});
