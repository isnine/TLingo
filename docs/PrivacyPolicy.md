# Privacy Policy

**Last Updated: February 13, 2026**

Zander Wang ("we," "our," or "us") operates the TLingo mobile application (the "App"). This Privacy Policy explains how we collect, use, disclose, and safeguard your information when you use our App, including any auto-renewable subscription services offered within the App.

By using TLingo, you agree to the collection and use of information in accordance with this policy.

## 1. Information We Collect

### 1.1 Translation Content

When you use TLingo to translate text, the following data is sent to a third-party AI service for processing:

- **Text you input** for translation
- **Source and target language** selections
- **Images you attach** (if using vision-capable models)
- **Translation instructions** (system prompts configured in the app)

This data is sent to **Microsoft Azure OpenAI Service** ("Azure OpenAI"), operated by Microsoft Corporation, to generate translations. We do not permanently store the content of your translations on our servers. Translation requests are processed in real time via streaming and are not retained after the response is delivered.

**Before any data is transmitted**, TLingo displays a consent dialog on first launch that clearly explains what data is shared, identifies the third-party service provider, and requires your explicit agreement before proceeding. You may decline, in which case no data will be sent to any third-party AI service.

### 1.2 Subscription Information

When you subscribe to TLingo Premium in the App Store, payment is processed by Apple. Web purchases are processed by Stripe. We do not collect, store, or have access to your payment information (such as credit card numbers). We only receive confirmation of your subscription status to provide you with premium features.

### 1.3 Device and Usage Data

We may collect limited, non-personally identifiable information such as:

- Device type and operating system version
- App version
- General usage analytics (e.g., feature usage frequency)

We do not collect personally identifiable information unless you voluntarily provide it (e.g., contacting support).

### 1.4 Configuration Data

TLingo stores your app preferences, custom API configurations, and settings locally on your device and within the App Group container. This data is used solely to provide and improve your experience and is not transmitted to us.

## 2. How We Use Your Information

We use the information we collect to:

- Provide, maintain, and improve the translation service
- Process and manage your subscription
- Respond to customer support inquiries
- Monitor and analyze usage trends to improve the App
- Ensure the security and integrity of our services

## 3. Third-Party Services

### 3.1 LLM API Providers

TLingo's built-in cloud translation service uses **Microsoft Azure OpenAI Service** to process your translation requests. When you use this service:

- **What data is sent**: Your input text, attached images (if any), source/target language, and translation instructions are sent to Azure OpenAI for processing.
- **Who receives the data**: Microsoft Corporation, through its Azure OpenAI Service. Microsoft processes this data in accordance with [Microsoft's Privacy Statement](https://privacy.microsoft.com/privacystatement) and [Azure OpenAI Data Privacy](https://learn.microsoft.com/legal/cognitive-services/openai/data-privacy).
- **Data protection**: Microsoft Azure OpenAI does not use customer data to train or improve its models. Your data is encrypted in transit and is not stored after processing.
- **User consent**: TLingo requires your explicit consent before sending any data to Azure OpenAI. A consent dialog is presented on first launch, and you may revoke consent at any time in Settings.

When requests are routed through our proxy server, they are authenticated using HMAC-SHA256 signatures. Our proxy server does not log or store your translation content.

#### User-Configured Custom API Providers

TLingo also allows you to configure your own OpenAI-compatible API endpoints. When using a custom provider:

- Your translation data is sent directly to the endpoint you configure.
- We have no control over how third-party providers handle your data.
- You are responsible for reviewing the privacy policies of any custom providers you configure.

### 3.2 Apple Services

TLingo uses Apple's StoreKit 2 framework to manage subscriptions. All payment processing is handled by Apple and is subject to [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

### 3.3 System Translation Extension

TLingo includes a system translation extension that integrates with iOS/macOS system-level translation features. The extension shares data with the main app only through the secure App Group container.

## 4. Data Sharing and Disclosure

Your translation data is shared with **Microsoft Azure OpenAI Service** solely for the purpose of generating translations. Microsoft provides equivalent data protection as described in Section 3.1.

We do not sell, trade, or rent your personal information to third parties. We may disclose information only in the following circumstances:

- **Translation Processing**: Your input text and related data are sent to Microsoft Azure OpenAI Service to perform translations, with your explicit consent
- **Legal Requirements**: If required by law, regulation, or legal process
- **Protection of Rights**: To protect our rights, privacy, safety, or property
- **With Your Consent**: When you have given explicit permission

## 5. Data Security

We implement reasonable technical and organizational measures to protect your information, including:

- HMAC-SHA256 authentication for cloud API requests
- Local storage of sensitive configuration data on-device
- No server-side retention of translation content

However, no method of electronic transmission or storage is 100% secure, and we cannot guarantee absolute security.

## 6. Data Retention

- **Translation content**: Not retained; processed in real time and discarded
- **Subscription status**: Cached locally on your device; refreshed from Apple's servers
- **App preferences**: Stored locally on your device until you delete the App

## 7. Children's Privacy

TLingo is not directed to children under the age of 13. We do not knowingly collect personal information from children under 13. If you believe we have inadvertently collected such information, please contact us so we can promptly delete it.

## 8. Your Rights

Depending on your jurisdiction, you may have the right to:

- Access the personal data we hold about you
- Request correction or deletion of your data
- Object to or restrict certain processing of your data
- Data portability

Since TLingo stores your data locally on your device and does not maintain user accounts, most data management can be performed by adjusting your App settings or deleting the App.

## 9. Changes to This Privacy Policy

We may update this Privacy Policy from time to time. We will notify you of any changes by updating the "Last Updated" date at the top of this policy. You are encouraged to review this Privacy Policy periodically.

## 10. Contact Us

If you have any questions or concerns about this Privacy Policy, please contact us at:

- **Email**: iamzanderwang@outlook.com
- **Support Page**: https://isnine.notion.site/2dc096d1267280748981e039ccc39f04
- **Terms of Use**: https://isnine.notion.site/Terms-of-Use-EULA-TLingo-304096d126728075b0d7c2e7578214c5
