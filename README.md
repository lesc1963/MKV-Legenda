# MKV Legenda

Aplicativo nativo para macOS que identifica, extrai e traduz faixas de legenda
de arquivos MKV. Todo o processamento acontece localmente no Mac.

## Recursos

- Abrir arquivos MKV por seleção ou arrastar e soltar.
- Identificar todas as faixas de legenda com `ffprobe`.
- Escolher a faixa e a pasta de destino.
- Converter legendas de texto para SRT.
- Preservar legendas baseadas em imagem em um contêiner MKS.
- Traduzir legendas de texto para português do Brasil.
- Preservar a numeração e os tempos originais do SRT.
- Mostrar o arquivo concluído diretamente no Finder.

Legendas de texto podem ser traduzidas para português do Brasil pela tecnologia de tradução da Apple. Os tempos do SRT são preservados, e o macOS solicita o download do idioma quando necessário. Esse recurso requer macOS 15 ou posterior.

## Requisitos

- macOS 15 ou posterior.
- Mac Apple Silicon (`arm64`).
- Xcode Command Line Tools.
- Homebrew e FFmpeg.

## Dependência FFmpeg

O aplicativo usa `ffmpeg` e `ffprobe`. Com Homebrew instalado:

```sh
brew install ffmpeg
```

## Compilar o aplicativo

```sh
chmod +x build-app.sh
./build-app.sh
```

O aplicativo será criado em `dist/MKV Legenda.app`. Ele pode ser movido para a pasta Aplicativos.

## Criar o ZIP para distribuição

```sh
chmod +x build-release.sh
./build-release.sh
```

O arquivo versionado será criado dentro da pasta `dist`.

Legendas de texto são convertidas para SRT. Quando a tradução está marcada, o aplicativo mantém o SRT original e cria outro com `.pt-BR.srt` no nome. Legendas baseadas em imagem ou formatos desconhecidos são preservadas em um contêiner MKS, mas não podem ser traduzidas sem OCR.

## Privacidade

O aplicativo não envia vídeos ou legendas para servidores próprios. A extração
usa o FFmpeg instalado no Mac, e a tradução usa a tecnologia nativa da Apple.
