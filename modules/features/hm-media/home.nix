{pkgsUnstable, ...}: {
  unfreeUnstable = ["yt-dlp"];

  home.packages = [
    pkgsUnstable.yt-dlp
  ];
}
