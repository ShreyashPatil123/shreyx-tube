import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/tube_models.dart';
import '../models/tube_user_profile.dart';
import 'tube_storage_service.dart';

/// Service managing the on-device user profile, learning signals, and multi-session feature weights.
class TubeUserProfileService {
  static final TubeUserProfileService _instance = TubeUserProfileService._internal();
  factory TubeUserProfileService() => _instance;
  TubeUserProfileService._internal();

  final TubeStorageService _storage = TubeStorageService();
  TubeUserProfile _profile = TubeUserProfile();
  bool _isLoaded = false;

  TubeUserProfile get profile => _profile;

  Future<void> init() async {
    if (_isLoaded) return;
    try {
      final jsonStr = await _storage.readStoreFile('user_profile.json');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        _profile = TubeUserProfile.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
      } else {
        _profile = TubeUserProfile();
      }
      _isLoaded = true;
    } catch (e) {
      debugPrint('[TubeUserProfileService] Init error: $e');
      _profile = TubeUserProfile();
      _isLoaded = true;
    }
  }

  Future<void> _saveProfile() async {
    try {
      _profile.lastUpdated = DateTime.now();
      await _storage.writeStoreFile('user_profile.json', jsonEncode(_profile.toJson()));
    } catch (e) {
      debugPrint('[TubeUserProfileService] Save error: $e');
    }
  }

  /// Extracts keywords/topics from a video title.
  List<String> extractTopics(String title) {
    final clean = title.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), ' ');
    final words = clean.split(RegExp(r'\s+')).where((w) => w.length > 3).toList();
    // Filter common stopwords
    const stops = {'this', 'that', 'with', 'from', 'have', 'what', 'video', 'official', 'about', 'your'};
    return words.where((w) => !stops.contains(w)).take(5).toList();
  }

  /// Processes watch behavior signal to update interest scores and adapt feature weights.
  Future<void> updateFromWatchSignal(TubeWatchSignal signal) async {
    await init();
    if (_storage.isIncognito || _storage.pausePersonalization) return;

    _profile.totalWatchSessions++;
    final topics = extractTopics(signal.title);
    final ratio = signal.completionRatio;

    // Track recently watched ID
    _profile.recentlyWatchedIds.remove(signal.videoId);
    _profile.recentlyWatchedIds.insert(0, signal.videoId);
    if (_profile.recentlyWatchedIds.length > 300) {
      _profile.recentlyWatchedIds.removeLast();
    }

    if (ratio >= 0.85) {
      // Strong positive signal: watched to completion
      for (final t in topics) {
        _profile.shortTermTopics[t] = ((_profile.shortTermTopics[t] ?? 0.0) + 0.30).clamp(0.0, 1.0);
        _profile.longTermTopics[t] = ((_profile.longTermTopics[t] ?? 0.0) + 0.10).clamp(0.0, 1.0);
        _profile.negativeTopics.remove(t);
      }
      _profile.shortTermChannels[signal.channelId] =
          ((_profile.shortTermChannels[signal.channelId] ?? 0.0) + 0.25).clamp(0.0, 1.0);
      _profile.longTermChannels[signal.channelId] =
          ((_profile.longTermChannels[signal.channelId] ?? 0.0) + 0.08).clamp(0.0, 1.0);

      _recordFeatureFeedback(success: true);
    } else if (ratio >= 0.45) {
      // Moderate positive signal
      for (final t in topics) {
        _profile.shortTermTopics[t] = ((_profile.shortTermTopics[t] ?? 0.0) + 0.15).clamp(0.0, 1.0);
        _profile.longTermTopics[t] = ((_profile.longTermTopics[t] ?? 0.0) + 0.05).clamp(0.0, 1.0);
      }
      _profile.shortTermChannels[signal.channelId] =
          ((_profile.shortTermChannels[signal.channelId] ?? 0.0) + 0.12).clamp(0.0, 1.0);

      _recordFeatureFeedback(success: true);
    } else if (ratio < 0.15 && signal.watchDurationSeconds < 30) {
      // Immediate skip / abandonment (negative signal)
      for (final t in topics) {
        _profile.negativeTopics[t] = ((_profile.negativeTopics[t] ?? 0.0) + 0.20).clamp(0.0, 1.0);
        _profile.shortTermTopics[t] = ((_profile.shortTermTopics[t] ?? 0.0) - 0.10).clamp(0.0, 1.0);
      }
      _profile.negativeChannels[signal.channelId] =
          ((_profile.negativeChannels[signal.channelId] ?? 0.0) + 0.15).clamp(0.0, 1.0);

      _recordFeatureFeedback(success: false);
    }

    // Apply smooth time decay across short-term signals
    _applyShortTermDecay();
    await _saveProfile();
  }

  /// Records search queries to rapidly align short-term recommendations.
  Future<void> recordSearchQuery(String query) async {
    await init();
    if (_storage.isIncognito || _storage.pausePersonalization) return;

    final tokens = extractTopics(query);
    for (final tok in tokens) {
      _profile.searchInterests[tok] = ((_profile.searchInterests[tok] ?? 0.0) + 0.35).clamp(0.0, 1.0);
      _profile.shortTermTopics[tok] = ((_profile.shortTermTopics[tok] ?? 0.0) + 0.20).clamp(0.0, 1.0);
    }
    await _saveProfile();
  }

  /// Records shown video impressions to avoid aggressive over-repetition.
  Future<void> recordImpressions(List<String> videoIds) async {
    await init();
    for (final id in videoIds) {
      _profile.recentlyShownIds.remove(id);
      _profile.recentlyShownIds.insert(0, id);
    }
    if (_profile.recentlyShownIds.length > 500) {
      _profile.recentlyShownIds = _profile.recentlyShownIds.take(500).toList();
    }
  }

  /// Multi-session gradual feature weight learning across accumulated evidence.
  void _recordFeatureFeedback({required bool success}) {
    // Only adapt feature weights once a stable volume of evidence is collected (>5 sessions)
    if (_profile.totalWatchSessions < 5) return;

    // Gradual learning rate: 0.03 per session
    const lr = 0.03;
    final keys = ['topicSimilarity', 'channelAffinity', 'freshness', 'popularity'];

    for (final k in keys) {
      final current = _profile.homeWeights[k] ?? 0.15;
      final target = success ? (current + 0.05).clamp(0.05, 0.40) : (current - 0.03).clamp(0.05, 0.40);
      _profile.homeWeights[k] = (1.0 - lr) * current + lr * target;
    }

    // Normalize weights to sum to 1.0
    final sum = _profile.homeWeights.values.fold(0.0, (a, b) => a + b);
    if (sum > 0) {
      _profile.homeWeights = _profile.homeWeights.map((k, v) => MapEntry(k, v / sum));
    }
  }

  void _applyShortTermDecay() {
    _profile.shortTermTopics = _profile.shortTermTopics.map(
      (k, v) => MapEntry(k, (v * 0.98).clamp(0.0, 1.0)),
    );
    _profile.shortTermChannels = _profile.shortTermChannels.map(
      (k, v) => MapEntry(k, (v * 0.98).clamp(0.0, 1.0)),
    );
  }
}
