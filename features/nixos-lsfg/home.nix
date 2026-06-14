_: let
  dllPath = "%h/.local/share/Lossless.dll";
  envMode = "1"; # don't use '$HOME/.config/lsfg-vk/conf.toml'
  multiplier = "2"; # set a default of 2x
  performanceMode = "1"; # default to true
in {
  # expect the user to copy/link 'Lossless.dll' or override the dll path themselves
  systemd.user.sessionVariables = {
    LSFG_LEGACY = envMode;
    LSFG_DLL_PATH = dllPath;
    LSFG_MULTIPLIER = multiplier;
    LSFG_PERFORMANCE_MODE = performanceMode;
    #
    DISABLE_LSFGVK = envMode; # force the user to use 'env -u DISABLE_LSFGVK'
    LSFGVK_DLL_PATH = dllPath;
    LSFGVK_MULTIPLIER = multiplier;
    LSFGVK_PERFORMANCE_MODE = performanceMode;
  };
}
