{pkgsUnstable, ...}: {
  unfree = ["yt-dlp"];

  home.packages = [
    pkgsUnstable.yt-dlp
  ];
}
