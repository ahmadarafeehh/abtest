import 'package:flutter/material.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:provider/provider.dart';

class ResponsiveLayout extends StatefulWidget {
  final Widget mobileScreenLayout;
  const ResponsiveLayout({
    Key? key,
    required this.mobileScreenLayout,
  }) : super(key: key);

  @override
  State<ResponsiveLayout> createState() => _ResponsiveLayoutState();
}

class _ResponsiveLayoutState extends State<ResponsiveLayout> {
  @override
  void initState() {
    super.initState();
    // Defer until after the first frame to avoid
    // "setState called during build" from UserProvider.refreshUser
    WidgetsBinding.instance.addPostFrameCallback((_) {
      addData();
    });
  }

  addData() async {
    UserProvider userProvider =
        Provider.of<UserProvider>(context, listen: false);
    await userProvider.refreshUser();
  }

  @override
  Widget build(BuildContext context) {
    // Always return mobile layout regardless of screen size
    return widget.mobileScreenLayout;
  }
}
