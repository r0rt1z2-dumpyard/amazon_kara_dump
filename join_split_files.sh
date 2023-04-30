#!/bin/bash

cat system/system/app/AmazonWebView/AmazonWebView.apk.* 2>/dev/null >> system/system/app/AmazonWebView/AmazonWebView.apk
rm -f system/system/app/AmazonWebView/AmazonWebView.apk.* 2>/dev/null
