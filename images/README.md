# Images Directory

This directory contains visual assets and branding materials for the OpenEMR on EKS deployment project.

## 📋 Table of Contents

### **📁 Directory Overview**
- [Directory Structure](#directory-structure)
  - [Visual Assets](#visual-assets)

### **📄 File Documentation**
- [File Descriptions](#file-descriptions)
  - [Deploy Training Setup Screenshot (`deploy-training-setup.png`)](#deploy-training-setup-screenshot-deploy-training-setuppng)
  - [Deploy Training Setup OpenEMR Login (`deploy-training-setup-openemr-login.png`)](#deploy-training-setup-openemr-login-deploy-training-setup-openemr-loginpng)
  - [Deploy Training Setup Patient Finder (`deploy-training-setup-patient-finder.png`)](#deploy-training-setup-patient-finder-deploy-training-setup-patient-finderpng)
  - [Deploy Training Setup Warp Data Upload (`deploy-training-setup-warp-data-upload.png`)](#deploy-training-setup-warp-data-upload-deploy-training-setup-warp-data-uploadpng)
  - [Destroy Screenshot (`destroy.png`)](#destroy-screenshot-destroypng)
  - [GitHub Banner (`openemr_on_eks_github_banner.png`)](#github-banner-openemr_on_eks_github_bannerpng)
  - [Grafana Login Screenshot (`quick-deploy-grafana-login.png`)](#grafana-login-screenshot-quick-deploy-grafana-loginpng)
  - [OpenEMR Admin Dashboard Screenshot (`quick-deploy-openemr-admin-landing-page.png`)](#openemr-admin-dashboard-screenshot-quick-deploy-openemr-admin-landing-pagepng)
  - [OpenEMR Grafana Dashboard Screenshot (`quick-deploy-openemr-grafana.png`)](#openemr-grafana-dashboard-screenshot-quick-deploy-openemr-grafanapng)
  - [OpenEMR Grafana Datasources (`quick-deploy-openemer-grafana-datasources.png`)](#openemr-grafana-datasources-quick-deploy-openemer-grafana-datasourcespng)
  - [OpenEMR Login Screenshot (`quick-deploy-openemr-login.png`)](#openemr-login-screenshot-quick-deploy-openemr-loginpng)
  - [Project Logo (`openemr_on_eks_logo.png`)](#project-logo-openemr_on_eks_logopng)
  - [Quick Deploy Screenshot (`quick-deploy.png`)](#quick-deploy-screenshot-quick-deploypng)
- [Setting GitHub Social Banner](#setting-github-social-banner)
  - [What is a GitHub Social Banner?](#what-is-a-github-social-banner)
  - [Why Set a Social Banner?](#why-set-a-social-banner)
  - [How to Set a GitHub Social Banner](#how-to-set-a-github-social-banner)
  - [Best Practices for GitHub Social Banners](#best-practices-for-github-social-banners)
  - [Troubleshooting Social Banner Issues](#troubleshooting-social-banner-issues)

### **📖 Usage Guidelines**
- [Usage Guidelines](#usage-guidelines)
  - [Logo Usage](#logo-usage)
  - [Banner Usage](#banner-usage)

### **🔧 Maintenance & Operations**
- [Maintenance Guidelines](#maintenance-guidelines)
  - [Adding New Images](#adding-new-images)
  - [Updating Existing Images](#updating-existing-images)
  - [File Management](#file-management)

### **🔗 References & Dependencies**
- [Cross-References](#cross-references)
  - [Related Documentation](#related-documentation)
  - [External Dependencies](#external-dependencies)

### **💡 Best Practices**
- [Best Practices](#best-practices)
  - [For Developers](#for-developers)
  - [For Maintainers](#for-maintainers)
  - [For Contributors](#for-contributors)

### **🛠️ Support & Troubleshooting**
- [Troubleshooting](#troubleshooting)
  - [Common Issues](#common-issues)
    - [Image Not Displaying](#image-not-displaying)
    - [Poor Image Quality](#poor-image-quality)
    - [Large File Sizes](#large-file-sizes)
  - [Debug Mode](#debug-mode)
- [Support and Contributing](#support-and-contributing)
  - [Getting Help](#getting-help)
  - [Contributing](#contributing)

---

## Directory Structure

### **Visual Assets**

- **`deploy-training-setup.png`** - Screenshot showing the training environment setup process
- **`deploy-training-setup-openemr-login.png`** - Screenshot showing the OpenEMR login page with newly generated admin credentials
- **`deploy-training-setup-patient-finder.png`** - Screenshot showing synthetic patients in OpenEMR's Patient Finder
- **`deploy-training-setup-warp-data-upload.png`** - Screenshot showing Warp uploading 100 synthetic patients in less than 1 minute
- **`destroy.png`** - Screenshot showing successful infrastructure destruction
- **`openemr_on_eks_github_banner.png`** - GitHub repository banner for social media and repository display
- **`openemr_on_eks_logo.png`** - Main project logo for documentation and branding (optimized for web)
- **`quick-deploy-grafana-login.png`** - Screenshot showing the Grafana login page after deployment
- **`quick-deploy-openemer-grafana-datasources.png`** - Screenshot showing 5 integrated datasources for dashboarding and alerting
- **`quick-deploy-openemr-admin-landing-page.png`** - Screenshot showing the OpenEMR admin dashboard landing page
- **`quick-deploy-openemr-grafana.png`** - Screenshot showing OpenEMR monitoring dashboard in Grafana
- **`quick-deploy-openemr-login.png`** - Screenshot showing the OpenEMR login page after deployment
- **`quick-deploy.png`** - Screenshot demonstrating the quick deployment script workflow

## File Descriptions

### **Deploy Training Setup Screenshot (`deploy-training-setup.png`)**

- **Purpose**: Visual demonstration of the training environment setup script (`scripts/deploy-training-openemr-setup.sh`)
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the training setup workflow
- **Context**: Illustrates the process for deploying OpenEMR training environments with pre-configured settings

### **Deploy Training Setup OpenEMR Login (`deploy-training-setup-openemr-login.png`)**

- **Purpose**: Visual demonstration of accessing the OpenEMR application after training setup deployment
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the OpenEMR login interface with newly generated admin credentials
- **Context**: Shows users what to expect when accessing OpenEMR after the training setup deployment

### **Deploy Training Setup Patient Finder (`deploy-training-setup-patient-finder.png`)**

- **Purpose**: Visual demonstration of verifying synthetic patient uploads in OpenEMR's Patient Finder
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show how to verify uploaded synthetic patients
- **Context**: Illustrates navigating to "Finder" → "Patient Finder" to see uploaded synthetic patients

### **Deploy Training Setup Warp Data Upload (`deploy-training-setup-warp-data-upload.png`)**

- **Purpose**: Visual demonstration of Warp uploading synthetic patient data
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the speed of Warp data uploads
- **Context**: Shows Warp uploading 100 synthetic patients in less than 1 minute

### **Destroy Screenshot (`destroy.png`)**

- **Purpose**: Visual demonstration of successful infrastructure destruction using the destroy script (`scripts/destroy.sh`)
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the cleanup workflow
- **Context**: Illustrates the complete infrastructure destruction process with the "DESTRUCTION COMPLETE!" success message

### **GitHub Banner (`openemr_on_eks_github_banner.png`)**

- **Purpose**: Social media banner for GitHub repository display
- **Format**: PNG image with transparency support
- **Usage**: Repository banner, social media sharing, and promotional materials
- **Dimensions**: Optimized for GitHub's banner display requirements

### **Grafana Login Screenshot (`quick-deploy-grafana-login.png`)**

- **Purpose**: Visual demonstration of accessing the Grafana monitoring interface after deployment
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the Grafana login page
- **Context**: Shows users how to access the monitoring stack that comes with the quick deployment

### **OpenEMR Admin Dashboard Screenshot (`quick-deploy-openemr-admin-landing-page.png`)**

- **Purpose**: Visual demonstration of the OpenEMR admin dashboard landing page
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the admin interface after login
- **Context**: Illustrates the admin dashboard that users will see after logging into OpenEMR

### **OpenEMR Grafana Dashboard Screenshot (`quick-deploy-openemr-grafana.png`)**

- **Purpose**: Visual demonstration of monitoring OpenEMR in the Grafana dashboard
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the monitoring capabilities
- **Context**: Illustrates the pre-configured Grafana dashboard that monitors OpenEMR deployment metrics and health

### **OpenEMR Grafana Datasources (`quick-deploy-openemer-grafana-datasources.png`)**

- **Purpose**: Visual demonstration of the 5 integrated datasources available in the monitoring stack
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show datasource configuration
- **Context**: Illustrates the comprehensive datasources available for dashboarding and alerting

### **OpenEMR Login Screenshot (`quick-deploy-openemr-login.png`)**

- **Purpose**: Visual demonstration of accessing the OpenEMR application after successful deployment
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the OpenEMR login interface
- **Context**: Shows users what to expect when accessing OpenEMR for the first time after deployment

### **Project Logo (`openemr_on_eks_logo.png`)**

- **Purpose**: Primary project logo used in documentation, README files, and branding materials
- **Format**: PNG image optimized for web display with transparency support
- **Usage**: Embedded in main README below the project title
- **Dimensions**: Optimized for various display sizes and contexts (<500KB file size for fast loading)

### **Quick Deploy Screenshot (`quick-deploy.png`)**

- **Purpose**: Visual demonstration of the quick deployment script (`scripts/quick-deploy.sh`) in action
- **Format**: PNG screenshot
- **Usage**: Documentation and README files to show the quick deployment workflow
- **Context**: Illustrates the streamlined deployment process for getting OpenEMR running on EKS quickly

## Setting GitHub Social Banner

### **What is a GitHub Social Banner?**

A GitHub social banner is a custom image that appears when your repository is shared on social media platforms like Twitter, LinkedIn, Facebook, and Discord. It provides a professional visual representation of your project and helps make your repository more engaging and recognizable.

### **Why Set a Social Banner?**

#### **Professional Appearance**
- **Enhanced Visibility**: Makes your repository stand out in social media feeds
- **Brand Recognition**: Establishes visual identity for your project
- **Professional Credibility**: Shows attention to detail and project maturity
- **Consistent Branding**: Maintains visual consistency across platforms

#### **Social Media Benefits**
- **Better Engagement**: Attractive banners increase click-through rates
- **Improved Sharing**: People are more likely to share visually appealing content
- **Project Promotion**: Helps promote your project effectively on social platforms
- **Community Building**: Creates a more professional image for contributors

### **How to Set a GitHub Social Banner**

#### **Step 1: Prepare Your Banner Image**

1. **Recommended Dimensions**: 1280x640 pixels (2:1 aspect ratio)
2. **File Format**: PNG or JPG (PNG preferred for transparency)
3. **File Size**: Keep under 1MB for optimal loading
4. **Content Guidelines**:
   - Include project name and key visual elements
   - Use high contrast for readability
   - Avoid small text that won't be readable when scaled
   - Consider how it looks on both light and dark backgrounds

#### **Step 2: Upload to Your Repository**

1. **Navigate to your repository** on GitHub
2. **Go to Settings** tab
3. **Scroll down to "Social preview"** section
4. **Click "Edit"** next to the social preview
5. **Upload your banner image** using the file picker
6. **Click "Save changes"** to apply

#### **Step 3: Verify the Banner**

1. **Test on different platforms**:
   - Share your repository URL on Twitter
   - Post on LinkedIn or Facebook
   - Check Discord embeds
2. **Ensure readability** at different sizes
3. **Verify it looks good** on both desktop and mobile

### **Best Practices for GitHub Social Banners**

#### **Design Guidelines**

- **Keep it Simple**: Avoid cluttered designs that are hard to read
- **High Contrast**: Ensure text and logos are clearly visible
- **Consistent Branding**: Use your project's color scheme and fonts
- **Mobile Friendly**: Test how it looks on smaller screens
- **Professional Tone**: Match the professional nature of your project

#### **Content Recommendations**

- **Project Name**: Clearly display the project title
- **Tagline**: Include a brief description or value proposition
- **Logo**: Feature your project logo prominently
- **Technology Stack**: Mention key technologies (e.g., "Kubernetes", "AWS", "Terraform")
- **Status Indicators**: Include badges for build status, version, or license

#### **Technical Considerations**

- **File Optimization**: Compress images without losing quality
- **Format Choice**: PNG for graphics with transparency, JPG for photographs
- **Loading Speed**: Keep file size reasonable for fast loading
- **Accessibility**: Ensure sufficient contrast for screen readers

### **Troubleshooting Social Banner Issues**

#### **Banner Not Appearing**

- **Check File Size**: Ensure it's under 1MB
- **Verify Format**: Use PNG or JPG format
- **Clear Cache**: Try refreshing or clearing browser cache
- **Wait Time**: Changes may take a few minutes to propagate

#### **Poor Image Quality**

- **Resolution**: Use at least 1280x640 pixels
- **Compression**: Avoid over-compressing the image
- **Format**: PNG often provides better quality than JPG
- **Source**: Use high-resolution source images

#### **Banner Not Updating**

- **Cache Issues**: Social media platforms cache images
- **Wait Time**: Allow 24-48 hours for full propagation
- **Force Refresh**: Try sharing the URL again after some time
- **Platform Differences**: Some platforms update faster than others

## Usage Guidelines

### **Logo Usage**

- **Primary Logo**: Use `openemr_on_eks_logo.png` for main documentation and branding
- **Consistent Placement**: Always place the logo below the main project title
- **Responsive Design**: Logo scales appropriately across different screen sizes
- **Brand Consistency**: Maintain consistent usage across all project materials

### **Banner Usage**

- **Repository Display**: Use `openemr_on_eks_github_banner.png` for GitHub repository banners
- **Social Media**: Suitable for sharing on social media platforms
- **Promotional Materials**: Can be used in presentations and promotional content

## Maintenance Guidelines

### **Adding New Images**

1. **Naming Convention**: Use descriptive, lowercase names with underscores
2. **Format Selection**:
   - Use JPEG for photographs and complex images
   - Use PNG for graphics with transparency
   - Use SVG for scalable vector graphics
3. **Optimization**: Compress images for web use while maintaining quality
4. **Documentation**: Update this README when adding new images

### **Updating Existing Images**

1. **Version Control**: Keep track of image updates and changes
2. **Backup**: Maintain backups of original high-resolution images
3. **Consistency**: Ensure updates maintain visual consistency
4. **Testing**: Verify images display correctly across different platforms

### **File Management**

- **Organization**: Keep images organized by purpose and usage
- **Naming**: Use consistent naming conventions for easy identification
- **Sizing**: Optimize images for their intended use cases
- **Accessibility**: Ensure images have appropriate alt text when used in documentation

## Cross-References

### **Related Documentation**

- **Main README**: Contains embedded logo and references to visual assets
- **Deployment Guide**: May reference visual assets for branding
- **GitHub Workflows**: May use banner for automated releases

### **External Dependencies**

- **GitHub**: Repository banner display requirements
- **Markdown**: Image embedding syntax and best practices
- **Web Browsers**: Cross-browser compatibility for image display

## Best Practices

### **For Developers**

- **Consistent Usage**: Always use the provided logo in documentation
- **Proper Attribution**: Maintain proper attribution for visual assets
- **Responsive Design**: Ensure images work across different screen sizes
- **Performance**: Optimize images for fast loading

### **For Maintainers**

- **Brand Consistency**: Maintain consistent visual identity across all materials
- **Quality Control**: Ensure all images meet quality standards
- **Version Management**: Track changes to visual assets
- **Documentation**: Keep this README updated with new assets

### **For Contributors**

- **Guidelines**: Follow established usage guidelines for visual assets
- **Format Standards**: Use appropriate formats for different use cases
- **Naming Conventions**: Follow established naming patterns
- **Documentation**: Update documentation when adding new visual assets

## Troubleshooting

### **Common Issues**

#### **Image Not Displaying**

- **Issue**: Logo or banner not appearing in documentation
- **Solution**: Check file path and ensure image exists in correct location
- **Verification**: Test image display in different browsers and platforms

#### **Poor Image Quality**

- **Issue**: Images appear pixelated or low quality
- **Solution**: Use higher resolution source images and optimize appropriately
- **Verification**: Test image quality at different zoom levels

#### **Large File Sizes**

- **Issue**: Images causing slow page load times
- **Solution**: Compress images while maintaining acceptable quality
- **Verification**: Test page load times with optimized images

### **Debug Mode**

When troubleshooting image issues:

1. **Check File Paths**: Verify image paths are correct and accessible
2. **Test Formats**: Ensure image formats are supported by target platforms
3. **Validate Markdown**: Check Markdown syntax for image embedding
4. **Browser Testing**: Test image display across different browsers
5. **Resolution Testing**: Verify images display correctly at different resolutions

## Support and Contributing

### **Getting Help**

- **Documentation Issues**: Check this README for usage guidelines
- **Technical Problems**: Refer to troubleshooting section above
- **Brand Guidelines**: Contact project maintainers for brand usage questions

### **Contributing**

- **New Assets**: Follow naming conventions and quality standards
- **Improvements**: Suggest enhancements to existing visual assets
- **Documentation**: Help maintain and improve this README
- **Testing**: Test visual assets across different platforms and use cases
