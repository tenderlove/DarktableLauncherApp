//
//  PhotoEditingViewController.swift
//  DarktableLauncher
//
//  Created by Aaron Patterson on 2/1/25.
//

import Cocoa
import Photos
import PhotosUI
import os
import AppKit

let EXT_NAME = "dev.tenderlove.DarktableLauncher"
let ADJUSTMENT_DATA_VERSION = "1"
let DARKTABLE_HOME = "/Applications/darktable.app/Contents/MacOS/"
let DARKTABLE_BIN = DARKTABLE_HOME + "darktable"
let DARKTABLE_CLI_BIN = DARKTABLE_HOME + "darktable-cli"

let logger = Logger(subsystem: EXT_NAME, category: "PhotoEditingViewController")

class PhotoEditingViewController: NSViewController, PHContentEditingController {

    var input: PHContentEditingInput?
    var imageURL: URL?
    var xmpURL: URL?
    var adjustmentData: PHAdjustmentData?
    var basedir = NSURL.fileURL(withPathComponents: [NSTemporaryDirectory(), NSUUID().uuidString])!

    @IBOutlet weak var imagePreview: NSImageCell!

    override func viewDidLoad() {
        super.viewDidLoad()
        // Make sure our base directory actually exists
        let fm = FileManager.default

        // If it somehow already exists, delete it
        if fm.fileExists(atPath: self.basedir.path) {
            do {
                try fm.removeItem(at: self.basedir)
            } catch {
                logger.log("couldn't remove directory")
            }
        }

        do {
            try fm.createDirectory(atPath: self.basedir.path, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.log("couldn't make temporary directory")
        }
    }

    // MARK: - PHContentEditingController

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        logger.log("adjustment data \(adjustmentData)")
        if adjustmentData.formatIdentifier == EXT_NAME && adjustmentData.formatVersion == ADJUSTMENT_DATA_VERSION {
            logger.log("we can deal with this adjustment data")
            self.adjustmentData = adjustmentData
            return true
        }
        logger.log("unknown adjustment data")
        return false
    }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: NSImage) {
        if let location = contentEditingInput.fullSizeImageURL {
            let fm = FileManager.default

            // We're going to copy the original asset to a temporary directory.
            // Then open darktable and point it at the file.
            let tempFileComponent = location.lastPathComponent

            let originalAssetURL = self.basedir.appending(path: tempFileComponent, directoryHint: .notDirectory)
            self.imageURL = originalAssetURL;

            do {
                logger.log("copying file, from: \(location) to: \(originalAssetURL)");
                try fm.copyItem(at: location, to: originalAssetURL)
            } catch {
                logger.log("couldn't copy")
            }

            // Calculate the corresponding XMP file name
            let xmpURL = self.basedir.appending(path: tempFileComponent + ".xmp", directoryHint: .notDirectory)

            // If we got adjustment data that we understand, it will
            // contain the contents of the XMP file.  Write the XMP
            // file contents out so that darktable has a history of the
            // edits.
            if let ad = self.adjustmentData {
                do {
                    try ad.data.write(to: xmpURL, options: .atomic)
                    logger.log("wrote to \(xmpURL)")
                } catch {
                    logger.log("couldn't write to xmp file")
                }

                // Render the JPG with the XMP file so we can show it in the preview
                do {
                    let previewURL = try self.renderPreviewJPG(rawPath: self.imageURL!, xmpPath: xmpURL)
                    logger.log("rendering JPG from previous edits \(previewURL)")
                    self.showImagePreview(imageURL: previewURL)
                } catch {
                    logger.log("showing original because of render fail")
                    self.showImagePreview(imageURL: originalAssetURL)
                }
            } else {
                logger.log("showing original")
                self.showImagePreview(imageURL: originalAssetURL)
            }

            self.xmpURL = xmpURL;

            // Finally start the darktable process.
            do {
                logger.log("starting darktable");
                let task = Process()
                task.launchPath = DARKTABLE_BIN
                task.arguments = ["--library", ":memory:", originalAssetURL.path]
                task.terminationHandler = { _ in
                    // When the process exits, set the "input" field so
                    // that the `finishContentEditing` callback knows that
                    // the process has finished.
                    self.input = contentEditingInput;
                }
                try task.run()
            } catch {
                logger.log("couldn't start the task")
            }
        }
    }

    func finishContentEditing(completionHandler: @escaping ((PHContentEditingOutput?) -> Void)) {
        // Render and provide output on a background queue.
        DispatchQueue.global().async {
            // If the input pointer is available, we know darktable closed.
            if let input = self.input {
                logger.log("we did it!")

                let fm = FileManager.default

                let output = PHContentEditingOutput(contentEditingInput: input)

                // First, render a JPG from the XML file that Photos can use.
                do {
                    let previewURL = try self.renderPreviewJPG(rawPath: self.imageURL!, xmpPath: self.xmpURL!)

                    // Second, move the rendered JPG to the location that Photos wants
                    do {
                        try fm.moveItem(at: previewURL, to: output.renderedContentURL)
                        logger.log("moved \(previewURL) to \(output.renderedContentURL)")
                    } catch {
                        logger.log("couldn't move file")
                        return
                    }
                } catch {
                    logger.log("couldn't render JPG")
                    return
                }

                if let it = self.xmpURL {
                    logger.log("it's done \(it.path)")
                    // Read the XMP file and put its contents in to the
                    // adjustmentData metadata object.
                    if let xmpData = try? Data(contentsOf: it) {
                        logger.log("Read XMP data \(xmpData)")
                        let adjustmentData = PHAdjustmentData(formatIdentifier: EXT_NAME, formatVersion: ADJUSTMENT_DATA_VERSION, data: xmpData)
                        output.adjustmentData = adjustmentData
                    }
                }

                // Move our tempdir to the trash
                do {
                    try fm.trashItem(at: self.basedir, resultingItemURL: nil)
                } catch {
                    logger.log("couldn't trash item")
                    return
                }

                // Tell everyone we've finished
                completionHandler(output)
            }
        }
    }

    var shouldShowCancelConfirmation: Bool {
        // Determines whether a confirmation to discard changes should be shown to the user on cancel.
        // (Typically, this should be "true" if there are any unsaved changes.)
        return false
    }

    func cancelContentEditing() {
        // Clean up temporary files, etc.
        // May be called after finishContentEditingWithCompletionHandler: while you prepare output.
    }

    func showImagePreview(imageURL: URL) {
        if let image = NSImage(contentsOfFile: imageURL.path) {
            self.imagePreview.image = image
        }

        logger.log("Failed to load image")
    }

    func renderPreviewJPG(rawPath: URL, xmpPath: URL) throws -> URL {
        // First check to see if the preview file exists.
        let previewURL = rawPath.deletingPathExtension().appendingPathExtension("jpg")

        let fm = FileManager.default
        // If it somehow already exists, delete it
        if fm.fileExists(atPath: previewURL.path) {
            do {
                try fm.removeItem(at: previewURL)
            } catch {
                logger.log("couldn't remove directory")
            }
        }
        renderJPG(rawPath: rawPath.path, xmpPath: xmpPath.path, outputFile: previewURL.path)

        return previewURL
    }

    func renderJPG(rawPath: String, xmpPath: String, outputFile: String) {
        let task = Process()
        task.launchPath = DARKTABLE_CLI_BIN
        task.arguments = [rawPath, xmpPath, outputFile]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logger.log("couldn't launch process")
        }
    }
}
