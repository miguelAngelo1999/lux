import 'package:flutter/material.dart';
import 'package:lux/core/core_manager.dart';

// TODO: Full rules page with CRUD, reorder, toggle
// For now shows a placeholder directing to the web dashboard
class RulesPage extends StatelessWidget {
  final CoreManager coreManager;
  const RulesPage({super.key, required this.coreManager});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Rules management\n(Coming soon)',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey),
      ),
    );
  }
}
